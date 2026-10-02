//
//  NextendoSettingsView.swift
//  MeloNX
//
//  Created for Nextendo-MeloNX Integration.
//

import SwiftUI
import AuthenticationServices
import CommonCrypto
import Security
import Network

struct PKCE {
    let verifier: String
    let challenge: String
    let state: String

    static func generate() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        
        guard let data = verifier.data(using: .utf8) else {
            return PKCE(verifier: verifier, challenge: verifier, state: UUID().uuidString)
        }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        let challenge = Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        
        let state = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return PKCE(verifier: verifier, challenge: challenge, state: state)
    }
}

class NextendoWebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = NextendoWebAuthPresenter()
    
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first as? UIWindowScene
        return windowScene?.windows.first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

class LoopbackOAuthListener {
    private var listener: NWListener?
    var onCallbackReceived: ((URL) -> Void)?
    private(set) var assignedPort: UInt16 = 80

    func start(completion: @escaping (UInt16?) -> Void) {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: 80)
            
            listener = try NWListener(using: params)
            listener?.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                if case .ready = state {
                    self.assignedPort = 80
                    completion(80)
                } else if case .failed = state {
                    self.startDynamicFallback(completion: completion)
                }
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            
            listener?.start(queue: .main)
        } catch {
            startDynamicFallback(completion: completion)
        }
    }

    private func startDynamicFallback(completion: @escaping (UInt16?) -> Void) {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: params)
            listener?.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                if case .ready = state {
                    if let p = self.listener?.port?.rawValue {
                        self.assignedPort = p
                        completion(p)
                    }
                } else if case .failed = state {
                    completion(nil)
                }
            }
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            listener?.start(queue: .main)
        } catch {
            completion(nil)
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, let requestStr = String(data: data, encoding: .utf8) else { return }
            
            let lines = requestStr.components(separatedBy: "\r\n")
            if let firstLine = lines.first, firstLine.contains("GET") {
                let parts = firstLine.components(separatedBy: " ")
                if parts.count >= 2 {
                    let pathAndQuery = parts[1]
                    let portStr = self.assignedPort == 80 ? "" : ":\(self.assignedPort)"
                    if let url = URL(string: "http://127.0.0.1\(portStr)\(pathAndQuery)") {
                        self.onCallbackReceived?(url)
                    }
                }
            }
            
            let responseHtml = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Connection: close\r
            \r
            <!DOCTYPE html>
            <html>
            <head><meta name="viewport" content="width=device-width, initial-scale=1"><title>Authorization Successful</title></head>
            <body style="font-family: -apple-system, sans-serif; text-align: center; padding: 50px 20px; background-color: #f2f2f7; color: #1c1c1e;">
                <div style="background: white; border-radius: 16px; padding: 30px; max-width: 400px; margin: 0 auto; box-shadow: 0 4px 12px rgba(0,0,0,0.1);">
                    <h2 style="color: #007aff; margin-bottom: 10px;">Authorization Successful!</h2>
                    <p style="color: #6c6c70; font-size: 15px;">Your device has been authorized with Nextendo Network.</p>
                    <p style="color: #8e8e93; font-size: 13px; margin-top: 20px;">You may now close this window and return to MeloNX.</p>
                </div>
            </body>
            </html>
            """
            connection.send(content: responseHtml.data(using: .utf8), completion: .contentProcessed({ _ in
                connection.cancel()
            }))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

struct SupportedGameInfo: Identifiable {
    let id = UUID()
    let name: String
    let titleId: String
    let engine: String
    let features: String
}

struct NextendoSettingsView: View {
    @ObservedObject public var nativeSettingsManager = NativeSettingsManager.shared
    
    // Core Network & Servers (Matching Nextendo Ryujinx NextendoEndpoint.cs)
    @AppStorage("enableNextendoOnline") private var enableNextendoOnline: Bool = true
    @AppStorage("nextendoServerUrl") private var nextendoServerUrl: String = "https://nextendo.network"
    
    // Custom Server Override Mode (Matching NextendoServerOverride.cs / HorsNextendo)
    @AppStorage("enableServerOverride") private var enableServerOverride: Bool = false
    @AppStorage("nextendoServerIp") private var nextendoServerIp: String = ""
    @AppStorage("nextendoNatIp") private var nextendoNatIp: String = ""
    
    // Account & Profile (Read-only)
    @AppStorage("nextendoUserPseudo") private var nextendoUserPseudo: String = ""
    @AppStorage("nextendoFriendCode") private var nextendoFriendCode: String = ""
    @AppStorage("nextendoAuthToken") private var nextendoAuthToken: String = ""
    @AppStorage("nextendoPid") private var nextendoPid: String = "0"
    
    // Services
    @AppStorage("enableNextendoCloudSave") private var enableNextendoCloudSave: Bool = true
    @AppStorage("enableNextendoNotifications") private var enableNextendoNotifications: Bool = true
    @AppStorage("enableGeoDns") private var enableGeoDns: Bool = true
    
    // Patches & Game Compat
    @AppStorage("enableAutoCertPatches") private var enableAutoCertPatches: Bool = true
    @AppStorage("enableNsoDump") private var enableNsoDump: Bool = false
    
    // State
    @State private var showingResetAlert = false
    @State private var authErrorMessage: String? = nil
    @State private var isAuthenticating = false
    @State private var authSession: ASWebAuthenticationSession? = nil
    @State private var loopbackListener: LoopbackOAuthListener? = nil
    @State private var isSupportedGamesExpanded = false
    @Environment(\.colorScheme) var colorScheme
    
    private let supportedGames: [SupportedGameInfo] = [
        SupportedGameInfo(name: "Super Mario Bros. Wonder (1.2.1)", titleId: "010015100B514000", engine: "NPLN (gRPC)", features: "Live Player Shadows, Standees, Friend Rooms, Auto TLS/Peer Bypasses"),
        SupportedGameInfo(name: "Pokémon Scarlet & Violet (3.0.1 / 4.0.0)", titleId: "0100A3D008C5C000", engine: "NPLN", features: "Poké Portal Battles, Tera Raids, Union Circle, Embedded TLS Bypasses, BCAT Delivery"),
        SupportedGameInfo(name: "Pokémon Legends: Z-A (2.0.2)", titleId: "0100F430154D0000", engine: "NPLN", features: "Online Matchmaking, Trading, Auto TLS & Peer Verification Patches"),
        SupportedGameInfo(name: "Splatoon 3", titleId: "0100C2500FC20000", engine: "NPLN (gRPC)", features: "Anarchy & Turf War Battles, Splatfests, BCAT Seed Delivery, Auto SSL Patches"),
        SupportedGameInfo(name: "Splatoon 2", titleId: "01005EE003C40000", engine: "NEX (PRUDP)", features: "Regular & Ranked Battles, Salmon Run, Stage Rotations, BAAS Token Signing"),
        SupportedGameInfo(name: "Mario Kart 8 Deluxe", titleId: "0100152000022000", engine: "NEX (PRUDP)", features: "Global/Regional Lobbies, Custom Tournaments, P2P Matchmaking, Friend Invites"),
        SupportedGameInfo(name: "Super Smash Bros. Ultimate", titleId: "01006A800016E000", engine: "NEX (PRUDP)", features: "Battle Arenas, Quickplay Matchmaking, Spectator Mode, Friend Rooms"),
        SupportedGameInfo(name: "Animal Crossing: New Horizons", titleId: "01006F8002326000", engine: "NEX (PRUDP)", features: "Dodo Code Airport Visits, Island Multiplayer, Best Friends"),
        SupportedGameInfo(name: "Crash Team Racing Nitro-Fueled (1.0.15)", titleId: "0100D7700B0DC000", engine: "Demonware", features: "Demonware RSA Key Patch, Expanded Friend Room Queries (300 user cap)"),
        SupportedGameInfo(name: "Nintendo 64 - Nintendo Classics (4.2.0)", titleId: "0100C9A00ECE6000", engine: "NPLN", features: "4-Player Online Netplay, Embedded TLS & Peer Hostname Patches"),
        SupportedGameInfo(name: "METAL GEAR SOLID: Peace Walker", titleId: "01000BD01ACCE000", engine: "NPLN", features: "Co-ops & Versus Ops, Integrated Certificate & Peer Bypasses"),
        SupportedGameInfo(name: "Overcooked! 2 (1.0.19)", titleId: "01006F7008074000", engine: "NEX / NPLN", features: "Online Arcade & Versus Kitchens, Integrated Cert & Peer Patches"),
        SupportedGameInfo(name: "Mario Tennis Aces", titleId: "0100B04005B30000", engine: "NEX / GeoDNS", features: "Online Tournaments, Free Play, GeoDNS Dynamic Server Routing"),
        SupportedGameInfo(name: "Luigi's Mansion 3", titleId: "0100DCA0064A6000", engine: "NEX (PRUDP)", features: "ScareScraper Co-op & ScreamPark Multiplayer Lobbies"),
        SupportedGameInfo(name: "Mario Golf: Super Rush", titleId: "0100537011400000", engine: "NEX (PRUDP)", features: "Standard & Speed Golf Matches, Global Ranked Tournaments"),
        SupportedGameInfo(name: "ARMS", titleId: "0100CA30000C2000", engine: "NEX (PRUDP)", features: "Party Match & Ranked Online Battles, Custom Lobbies")
    ]
    
    var truncatedToken: String {
        guard !nextendoAuthToken.isEmpty else { return "Not Authorized" }
        let prefixCount = min(7, nextendoAuthToken.count)
        let prefix = String(nextendoAuthToken.prefix(prefixCount))
        let dots = String(repeating: "•", count: max(12, nextendoAuthToken.count - prefixCount))
        return "\(prefix)\(dots)"
    }
    
    var body: some View {
        Form {
            // Section 1: Overview Banner
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "globe.americas.fill")
                            .font(.title)
                            .foregroundColor(.blue)
                        VStack(alignment: .leading) {
                            Text("Nextendo")
                                .font(.headline)
                            Text("Custom Nintendo Switch Online Infrastructure")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Text("Enables out-of-the-box online multiplayer, DNS redirection, cloud save sync, friend activity, and embedded SSL certificate bypasses.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
            
            // Section 2: Account & Profile (Read-only + Web Device Auth via ASWebAuthenticationSession)
            Section(header: Text("Account & Profile")) {
                HStack {
                    Text("Display Name")
                        .font(.subheadline)
                    Spacer()
                    Text(nextendoUserPseudo.isEmpty ? "Guest Player" : nextendoUserPseudo)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .contextMenu {
                    Button(action: {
                        UIPasteboard.general.string = nextendoUserPseudo.isEmpty ? "Guest Player" : nextendoUserPseudo
                    }) {
                        Label("Copy Display Name", systemImage: "doc.on.doc")
                    }
                }
                
                HStack {
                    Text("Friend Code")
                        .font(.subheadline)
                    Spacer()
                    Text(nextendoFriendCode.isEmpty ? "SW-0000-0000-0000" : nextendoFriendCode)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .contextMenu {
                    Button(action: {
                        UIPasteboard.general.string = nextendoFriendCode.isEmpty ? "SW-0000-0000-0000" : nextendoFriendCode
                    }) {
                        Label("Copy Friend Code", systemImage: "doc.on.doc")
                    }
                }
                
                HStack {
                    Text("Account Token")
                        .font(.subheadline)
                    Spacer()
                    Text(truncatedToken)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(nextendoAuthToken.isEmpty ? .secondary : .blue)
                }
                
                if nextendoAuthToken.isEmpty {
                    Button(action: {
                        startASWebAuthenticationSession()
                    }) {
                        HStack {
                            Label("Device Authorization (Sign In)", systemImage: "key.fill")
                                .font(.subheadline)
                            Spacer()
                            if isAuthenticating {
                                ProgressView()
                            } else {
                                Image(systemName: "safari.fill")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                } else {
                    Button(role: .destructive, action: {
                        nextendoAuthToken = ""
                        nextendoUserPseudo = ""
                        nextendoFriendCode = ""
                        nextendoPid = "0"
                        UserDefaults.standard.removeObject(forKey: "nextendoMiiData")
                        let accountFilePath = URL.documentsDirectory.appendingPathComponent("nextendo_account.txt")
                        try? FileManager.default.removeItem(at: accountFilePath)
                        initEnvironmentVariables()
                    }) {
                        HStack {
                            Label("Sign Out", systemImage: "door.left.hand.open")
                                .font(.subheadline)
                                .foregroundColor(.red)
                            Spacer()
                        }
                    }
                }
                
                Link(destination: URL(string: "https://nextendo.network/compte")!) {
                    HStack {
                        Label("Change Account Settings", systemImage: "arrow.up.right.square")
                            .font(.subheadline)
                        Spacer()
                    }
                }
            }
            
            // Section 3: Core Network Configuration
            Section(header: Text("Network Configuration")) {
                Toggle(isOn: Binding(
                    get: { self.enableNextendoOnline },
                    set: { newValue in
                        self.enableNextendoOnline = newValue
                        if newValue {
                            self.enableServerOverride = false
                        }
                    }
                )) {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Enable Nextendo Network")
                            Text("Redirects NSO server domains via DNS MITM")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "network")
                            .foregroundColor(.blue)
                    }
                }
            }
            
            // Section 4: Custom Server Override Mode (Private LAN / Self-Hosted)
            Section(header: Text("Custom Server Override (Private Mode)"), footer: Text("Allows connecting to self-hosted or private community servers outside Nextendo Network.")) {
                Toggle(isOn: Binding(
                    get: { self.enableServerOverride },
                    set: { newValue in
                        self.enableServerOverride = newValue
                        if newValue {
                            self.enableNextendoOnline = false
                        }
                    }
                )) {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Enable Custom Server Override")
                            Text("Disables Nextendo account features & routes traffic to custom IP")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "server.rack")
                            .foregroundColor(.purple)
                    }
                }
                
                if enableServerOverride {
                    HStack {
                        Text("Server API URL")
                            .font(.subheadline)
                        Spacer()
                        TextField("https://nextendo.network", text: $nextendoServerUrl)
                            .multilineTextAlignment(.trailing)
                            .font(.subheadline)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    
                    HStack {
                        Text("Custom Game Server IP")
                            .font(.subheadline)
                        Spacer()
                        TextField("Empty (No IP)", text: $nextendoServerIp)
                            .multilineTextAlignment(.trailing)
                            .font(.subheadline)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    
                    HStack {
                        Text("Custom NAT Responder IP")
                            .font(.subheadline)
                        Spacer()
                        TextField("Empty (No IP)", text: $nextendoNatIp)
                            .multilineTextAlignment(.trailing)
                            .font(.subheadline)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                }
            }
            
            // Section 5: Cloud & Social Services
            Section(header: Text("Cloud & Social Services")) {
                Toggle(isOn: $enableNextendoCloudSave) {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Cloud Save Auto-Sync")
                            Text("Auto pull before launch & push on exit")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "icloud.and.arrow.up")
                            .foregroundColor(.green)
                    }
                }
                
                Toggle(isOn: $enableNextendoNotifications) {
                    Label {
                        VStack(alignment: .leading) {
                            Text("In-Game Friend Notifications")
                            Text("Show overlay toasts for friend requests & lobby invites")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "bell.badge.fill")
                            .foregroundColor(.orange)
                    }
                }
            }
            
            // Section 6: Matchmaking & SSL Patches
            Section(header: Text("Matchmaking & Patches")) {
                Toggle(isOn: $enableGeoDns) {
                    Label {
                        VStack(alignment: .leading) {
                            Text("GeoDNS Dynamic Routing")
                            Text("Routes Mario Tennis Aces via tennis-geo.nextendo.network")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "location.fill")
                            .foregroundColor(.teal)
                    }
                }
                
                Toggle(isOn: $enableAutoCertPatches) {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Auto SSL Cert Patches")
                            Text("Bypasses SSL pinning for Splatoon 3, Mario Tennis, etc.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(.indigo)
                    }
                }
                
                Toggle(isOn: $enableNsoDump) {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Dump NSO Executables")
                            Text("Saves decompressed NSO images for patch development")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "square.and.arrow.down")
                            .foregroundColor(.gray)
                    }
                }
                
                DisclosureGroup(
                    isExpanded: $isSupportedGamesExpanded,
                    content: {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(supportedGames) { game in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(game.name)
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                        Spacer()
                                        Text(game.engine)
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Color.blue.opacity(0.15)))
                                            .foregroundColor(.blue)
                                    }
                                    Text("Title ID: \(game.titleId)")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    Text(game.features)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                if game.id != supportedGames.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    },
                    label: {
                        HStack {
                            Label("Supported Titles (\(supportedGames.count))", systemImage: "gamecontroller.fill")
                                .font(.subheadline)
                            Spacer()
                        }
                    }
                )
            }
            
            // Section 7: Reset Defaults
            Section {
                Button(role: .destructive) {
                    showingResetAlert = true
                } label: {
                    HStack {
                        Spacer()
                        Text("Reset Nextendo Settings to Defaults")
                        Spacer()
                    }
                }
            }
        }
        .onChange(of: enableNextendoOnline) { _ in initEnvironmentVariables() }
        .onChange(of: enableServerOverride) { _ in initEnvironmentVariables() }
        .onChange(of: nextendoServerUrl) { _ in initEnvironmentVariables() }
        .onChange(of: nextendoServerIp) { _ in initEnvironmentVariables() }
        .onChange(of: nextendoNatIp) { _ in initEnvironmentVariables() }
        .onChange(of: enableNsoDump) { _ in initEnvironmentVariables() }
        .alert("Auth System Message", isPresented: Binding(
            get: { authErrorMessage != nil },
            set: { if !$0 { authErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(authErrorMessage ?? "")
        }
        .alert("Reset Settings", isPresented: $showingResetAlert) {
            Button("Reset", role: .destructive) {
                enableNextendoOnline = true
                nextendoServerUrl = "https://nextendo.network"
                enableServerOverride = false
                nextendoServerIp = ""
                nextendoNatIp = ""
                nextendoUserPseudo = ""
                nextendoFriendCode = ""
                nextendoAuthToken = ""
                nextendoPid = "0"
                UserDefaults.standard.removeObject(forKey: "nextendoMiiData")
                enableNextendoCloudSave = true
                enableNextendoNotifications = true
                enableGeoDns = true
                enableAutoCertPatches = true
                enableNsoDump = false
                let accountFilePath = URL.documentsDirectory.appendingPathComponent("nextendo_account.txt")
                try? FileManager.default.removeItem(at: accountFilePath)
                initEnvironmentVariables()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to reset all Nextendo settings to their default values?")
        }
    }
    
    private func startASWebAuthenticationSession() {
        let listener = LoopbackOAuthListener()
        self.loopbackListener = listener
        
        listener.start { port in
            DispatchQueue.main.async {
                guard let port = port else {
                    self.authErrorMessage = "Could not start local loopback listener."
                    return
                }
                
                let pkce = PKCE.generate()
                let redirectUri = port == 80 ? "http://127.0.0.1/callback" : "http://127.0.0.1:\(port)/callback"
                let rawBase = self.nextendoServerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                let baseUrl = rawBase.isEmpty ? "https://nextendo.network" : rawBase
                
                var components = URLComponents(string: "\(baseUrl)/api/oauth/authorize")
                components?.queryItems = [
                    URLQueryItem(name: "response_type", value: "code"),
                    URLQueryItem(name: "client_id", value: "nextendo-emulator"),
                    URLQueryItem(name: "redirect_uri", value: redirectUri),
                    URLQueryItem(name: "scope", value: "identity friends"),
                    URLQueryItem(name: "state", value: pkce.state),
                    URLQueryItem(name: "code_challenge", value: pkce.challenge),
                    URLQueryItem(name: "code_challenge_method", value: "S256")
                ]
                
                guard let authUrl = components?.url else { return }
                
                self.isAuthenticating = true
                
                listener.onCallbackReceived = { callbackUrl in
                    DispatchQueue.main.async {
                        self.isAuthenticating = false
                        self.authSession?.cancel()
                        self.authSession = nil
                        self.loopbackListener?.stop()
                        self.loopbackListener = nil
                        self.parseOAuthCallback(url: callbackUrl, pkce: pkce, redirectUri: redirectUri, baseUrl: baseUrl)
                    }
                }
                
                let session = ASWebAuthenticationSession(url: authUrl, callbackURLScheme: "http") { callbackUrl, error in
                    DispatchQueue.main.async {
                        self.isAuthenticating = false
                        self.authSession = nil
                        self.loopbackListener?.stop()
                        self.loopbackListener = nil
                        
                        if let callbackUrl = callbackUrl {
                            self.parseOAuthCallback(url: callbackUrl, pkce: pkce, redirectUri: redirectUri, baseUrl: baseUrl)
                        } else if let error = error as? ASWebAuthenticationSessionError {
                            if error.code != .canceledLogin {
                                self.authErrorMessage = "Sign in error: \(error.localizedDescription)"
                            }
                        }
                    }
                }
                
                session.presentationContextProvider = NextendoWebAuthPresenter.shared
                session.prefersEphemeralWebBrowserSession = false
                self.authSession = session
                session.start()
            }
        }
    }
    
    private func parseOAuthCallback(url: URL, pkce: PKCE, redirectUri: String, baseUrl: String) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else { return }
        
        var code: String? = nil
        var errorStr: String? = nil
        
        for item in queryItems {
            if item.name == "code" { code = item.value }
            if item.name == "error" { errorStr = item.value }
            if item.name == "nex_token", let value = item.value, !value.isEmpty {
                nextendoAuthToken = value
                return
            }
        }
        
        if let errorStr = errorStr {
            authErrorMessage = "Authorization failed: \(errorStr)"
            return
        }
        
        guard let authCode = code, !authCode.isEmpty else { return }
        
        exchangeCodeForToken(code: authCode, pkce: pkce, redirectUri: redirectUri, baseUrl: baseUrl)
    }
    
    private func exchangeCodeForToken(code: String, pkce: PKCE, redirectUri: String, baseUrl: String) {
        guard let tokenUrl = URL(string: "\(baseUrl)/api/oauth/token") else { return }
        
        var request = URLRequest(url: tokenUrl)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let bodyComponents = [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": "nextendo-emulator",
            "redirect_uri": redirectUri,
            "code_verifier": pkce.verifier
        ]
        
        let bodyString = bodyComponents.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.authErrorMessage = "Token exchange failed: \(error.localizedDescription)"
                    return
                }
                
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.authErrorMessage = "Invalid response from Nextendo server."
                    return
                }
                
                if let nexToken = json["nex_token"] as? String, !nexToken.isEmpty {
                    self.nextendoAuthToken = nexToken
                    
                    var usernameStr = ""
                    var friendCodeStr = ""
                    var pidVal: UInt64 = 0
                    
                    if let account = json["account"] as? [String: Any] {
                        if let username = account["username"] as? String {
                            self.nextendoUserPseudo = username
                            usernameStr = username
                        }
                        if let friendCode = account["friend_code"] as? String {
                            self.nextendoFriendCode = friendCode
                            friendCodeStr = friendCode
                        }
                        if let pidNum = account["pid"] as? UInt64 {
                            pidVal = pidNum
                        } else if let pidInt = account["pid"] as? Int {
                            pidVal = UInt64(pidInt)
                        } else if let pidStr = account["pid"] as? String, let parsed = UInt64(pidStr) {
                            pidVal = parsed
                        }
                    }
                    self.nextendoPid = String(pidVal)
                    
                    let finalUsername = usernameStr.isEmpty ? self.nextendoUserPseudo : usernameStr
                    self.syncNextendoProfile(username: finalUsername.isEmpty ? "Nextendo" : finalUsername, token: nexToken, baseUrl: baseUrl, pid: pidVal, friendCode: friendCodeStr)
                } else if let errorMsg = json["error"] as? String {
                    self.authErrorMessage = "Authorization error: \(errorMsg)"
                } else {
                    self.authErrorMessage = "Could not retrieve NEX token."
                }
            }
        }.resume()
    }
    
    private func syncNextendoProfile(username: String, token: String, baseUrl: String, pid: UInt64, friendCode: String) {
        let profilePath = URL.documentsDirectory.appendingPathComponent("system").appendingPathComponent("Profiles.json")
        guard let profileUrl = URL(string: "\(baseUrl)/api/profile") else {
            self.applyProfileToRyujinx(name: username, imageData: generateDefaultAvatar(name: username), profilePath: profilePath, pid: pid, nexToken: token, friendCode: friendCode)
            return
        }
        
        var request = URLRequest(url: profileUrl)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            var avatarData: Data? = nil
            var profileName = username
            var finalPid = pid
            var finalFriendCode = friendCode
            var finalMiiB64 = ""
            
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let profileDict = json["profile"] as? [String: Any] {
                if let name = profileDict["name"] as? String, !name.isEmpty {
                    profileName = name
                }
                if let imageB64 = profileDict["image"] as? String, let decoded = Data(base64Encoded: imageB64) {
                    avatarData = decoded
                }
                if let fc = profileDict["friend_code"] as? String, !fc.isEmpty {
                    finalFriendCode = fc
                }
                if let mii = profileDict["mii"] as? String, !mii.isEmpty {
                    finalMiiB64 = mii
                }
                if let pidNum = profileDict["pid"] as? UInt64 {
                    finalPid = pidNum
                } else if let pidInt = profileDict["pid"] as? Int {
                    finalPid = UInt64(pidInt)
                } else if let pidStr = profileDict["pid"] as? String, let parsed = UInt64(pidStr) {
                    finalPid = parsed
                }
            }
            
            let finalImageData = avatarData ?? self.generateDefaultAvatar(name: profileName)
            
            DispatchQueue.main.async {
                if finalPid != 0 {
                    self.nextendoPid = String(finalPid)
                }
                if !finalFriendCode.isEmpty {
                    self.nextendoFriendCode = finalFriendCode
                }
                if !finalMiiB64.isEmpty {
                    UserDefaults.standard.set(finalMiiB64, forKey: "nextendoMiiData")
                    if let miiBytes = Data(base64Encoded: finalMiiB64) {
                        Ryujinx.injectNextendoMii(data: miiBytes)
                    }
                }
                self.applyProfileToRyujinx(name: profileName, imageData: finalImageData, profilePath: profilePath, pid: finalPid, nexToken: token, friendCode: finalFriendCode, miiData: finalMiiB64)
            }
        }.resume()
    }

    private func applyProfileToRyujinx(name: String, imageData: Data, profilePath: URL, pid: UInt64, nexToken: String, friendCode: String, miiData: String = "") {
        var profilesObj: Profiles? = nil
        if let data = try? Data(contentsOf: profilePath) {
            profilesObj = try? JSONDecoder().decode(Profiles.self, from: data)
        }
        
        var openedUserId = ""
        if var profiles = profilesObj, let existing = profiles.profiles.first(where: { $0.name == name }) {
            openedUserId = existing.user_id
            if profiles.last_opened != existing.user_id {
                Ryujinx.closeUser(userId: profiles.last_opened)
                Ryujinx.openUser(userId: existing.user_id)
                profiles.last_opened = existing.user_id
                
                if let encoded = try? JSONEncoder().encode(profiles) {
                    try? encoded.write(to: profilePath)
                }
                Ryujinx.refreshAccountManager()
            }
        } else {
            Ryujinx.createAccount(name: name, image: imageData)
            
            if let updatedData = try? Data(contentsOf: profilePath),
               var newProfiles = try? JSONDecoder().decode(Profiles.self, from: updatedData),
               let createdProfile = newProfiles.profiles.first(where: { $0.name == name }) {
                openedUserId = createdProfile.user_id
                if newProfiles.last_opened != createdProfile.user_id {
                    Ryujinx.closeUser(userId: newProfiles.last_opened)
                    Ryujinx.openUser(userId: createdProfile.user_id)
                    newProfiles.last_opened = createdProfile.user_id
                    
                    if let encoded = try? JSONEncoder().encode(newProfiles) {
                        try? encoded.write(to: profilePath)
                    }
                    Ryujinx.refreshAccountManager()
                }
            }
        }
        
        self.writeNextendoAccountFile(pid: pid, username: name, friendCode: friendCode, nexToken: nexToken, profileUserId: openedUserId, miiData: miiData)
    }

    private func writeNextendoAccountFile(pid: UInt64, username: String, friendCode: String, nexToken: String, profileUserId: String, miiData: String = "") {
        let accountFilePath = URL.documentsDirectory.appendingPathComponent("nextendo_account.txt")
        let cleanProfileUserId = profileUserId.replacingOccurrences(of: "-", with: "")
        let effectiveMii = miiData.isEmpty ? (UserDefaults.standard.string(forKey: "nextendoMiiData") ?? "") : miiData
        let content = """
        pid=\(pid)
        username=\(username)
        friend_code=\(friendCode)
        nex_token=\(nexToken)
        profile_user_id=\(cleanProfileUserId)
        mii_data=\(effectiveMii)
        is_guest=0
        """
        try? content.write(to: accountFilePath, atomically: true, encoding: .utf8)
        initEnvironmentVariables()
    }

    private func generateDefaultAvatar(name: String) -> Data {
        let size = CGSize(width: 256, height: 256)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            
            let initial = String(name.prefix(1)).uppercased()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 120, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            let textSize = initial.size(withAttributes: attributes)
            let rect = CGRect(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            initial.draw(in: rect, withAttributes: attributes)
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }
}

struct NextendoTabView: View {
    var body: some View {
        NavigationStack {
            NextendoSettingsView()
                .navigationTitle("Nextendo")
        }
    }
}

struct NextendoSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            NextendoSettingsView()
        }
    }
}
