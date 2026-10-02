//
//  NextendoSettingsView.swift
//  MeloNX
//
//  Created for Nextendo-MeloNX Integration.
//

import SwiftUI
import CommonCrypto
import Security
import WebKit

struct NextendoOAuthWebView: UIViewControllerRepresentable {
    let authUrl: URL
    let onCallback: (URL) -> Void
    let onCancel: () -> Void
    
    func makeUIViewController(context: Context) -> UINavigationController {
        let webVC = OAuthWebViewController(authUrl: authUrl, onCallback: onCallback, onCancel: onCancel)
        let nav = UINavigationController(rootViewController: webVC)
        nav.modalPresentationStyle = .fullScreen
        return nav
    }
    
    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}

class OAuthWebViewController: UIViewController, WKNavigationDelegate {
    let authUrl: URL
    let onCallback: (URL) -> Void
    let onCancel: () -> Void
    private var webView: WKWebView!
    private var progressView: UIProgressView!
    private var progressObserver: NSKeyValueObservation?
    
    init(authUrl: URL, onCallback: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
        self.authUrl = authUrl
        self.onCallback = onCallback
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Sign In with Nextendo"
        view.backgroundColor = .systemBackground
        
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )
        
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        
        progressView = UIProgressView(progressViewStyle: .bar)
        progressView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressView)
        
        NSLayoutConstraint.activate([
            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2),
            
            webView.topAnchor.constraint(equalTo: progressView.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        progressObserver = webView.observe(\.estimatedProgress, options: .new) { [weak self] webView, _ in
            self?.progressView.progress = Float(webView.estimatedProgress)
            self?.progressView.isHidden = webView.estimatedProgress >= 1.0
        }
        
        webView.load(URLRequest(url: authUrl))
    }
    
    @objc private func cancelTapped() {
        onCancel()
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url {
            let redirectScheme = URL(string: NextendoSecrets.defaultRedirectUri)?.scheme ?? "melonx"
            if url.scheme?.lowercased() == redirectScheme.lowercased() {
                decisionHandler(.cancel)
                onCallback(url)
                return
            }
        }
        decisionHandler(.allow)
    }
}

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
    @AppStorage("nextendoServerUrl") private var nextendoServerUrl: String = NextendoSecrets.defaultServerUrl
    
    // Custom Server Override Mode (Private LAN / Self-Hosted, distinct from Nextendo mode)
    @AppStorage("enableServerOverride") private var enableServerOverride: Bool = false
    @AppStorage("customServerUrl") private var customServerUrl: String = ""
    @AppStorage("customServerIp") private var customServerIp: String = ""
    @AppStorage("customNatIp") private var customNatIp: String = ""
    
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
    @State private var showingFullPageOAuth = false
    @State private var currentAuthUrl: URL? = nil
    @State private var currentCodeVerifier: String = ""
    @State private var currentOAuthState: String = ""
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
                
                if NextendoSecrets.isOAuthEnabled {
                    if nextendoAuthToken.isEmpty {
                        Button(action: {
                            startFullPageOAuth()
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
                            NextendoKeychainHelper.deleteToken()
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
                    
                    Link(destination: URL(string: "\(nextendoServerUrl.isEmpty ? NextendoSecrets.defaultServerUrl : nextendoServerUrl)/compte") ?? URL(string: "https://nextendo.network/compte")!) {
                        HStack {
                            Label("Change Account Settings", systemImage: "arrow.up.right.square")
                                .font(.subheadline)
                            Spacer()
                        }
                    }
                } else {
                    HStack {
                        Label("Nextendo OAuth", systemImage: "key.slash")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("Disabled (Build Unconfigured)")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
                        Text("Custom Server URL")
                            .font(.subheadline)
                        Spacer()
                        TextField("e.g. http://192.168.1.100:8000", text: $customServerUrl)
                            .multilineTextAlignment(.trailing)
                            .font(.subheadline)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    
                    HStack {
                        Text("Custom Game Server IP")
                            .font(.subheadline)
                        Spacer()
                        TextField("e.g. 192.168.1.100", text: $customServerIp)
                            .multilineTextAlignment(.trailing)
                            .font(.subheadline)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    
                    HStack {
                        Text("Custom NAT Responder IP")
                            .font(.subheadline)
                        Spacer()
                        TextField("e.g. 192.168.1.100", text: $customNatIp)
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
        .onChange(of: customServerUrl) { _ in initEnvironmentVariables() }
        .onChange(of: customServerIp) { _ in initEnvironmentVariables() }
        .onChange(of: customNatIp) { _ in initEnvironmentVariables() }
        .onChange(of: enableNsoDump) { _ in initEnvironmentVariables() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NextendoOAuthCallback"))) { notification in
            if let callbackUrl = notification.object as? URL {
                let rawBase = nextendoServerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                let baseUrl = rawBase.isEmpty ? NextendoSecrets.defaultServerUrl : rawBase
                self.showingFullPageOAuth = false
                self.parseOAuthCallback(url: callbackUrl, codeVerifier: self.currentCodeVerifier, redirectUri: NextendoSecrets.defaultRedirectUri, baseUrl: baseUrl, clientId: NextendoSecrets.oauthClientId)
            }
        }
        .fullScreenCover(isPresented: $showingFullPageOAuth) {
            if let authUrl = currentAuthUrl {
                NextendoOAuthWebView(authUrl: authUrl) { callbackUrl in
                    self.showingFullPageOAuth = false
                    self.isAuthenticating = false
                    let rawBase = nextendoServerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                    let baseUrl = rawBase.isEmpty ? NextendoSecrets.defaultServerUrl : rawBase
                    self.parseOAuthCallback(url: callbackUrl, codeVerifier: self.currentCodeVerifier, redirectUri: NextendoSecrets.defaultRedirectUri, baseUrl: baseUrl, clientId: NextendoSecrets.oauthClientId)
                } onCancel: {
                    self.showingFullPageOAuth = false
                    self.isAuthenticating = false
                }
                .ignoresSafeArea()
            }
        }
        .onAppear {
            guard NextendoSecrets.isOAuthEnabled else { return }
            if let token = NextendoKeychainHelper.loadToken(), !token.isEmpty {
                if nextendoAuthToken != token {
                    nextendoAuthToken = token
                }
            } else if !nextendoAuthToken.isEmpty {
                NextendoKeychainHelper.saveToken(nextendoAuthToken)
            }
        }
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
                nextendoServerUrl = NextendoSecrets.defaultServerUrl
                enableServerOverride = false
                customServerUrl = ""
                customServerIp = ""
                customNatIp = ""
                UserDefaults.standard.removeObject(forKey: "nextendoServerIp")
                UserDefaults.standard.removeObject(forKey: "nextendoNatIp")
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
    
    private func startFullPageOAuth() {
        guard NextendoSecrets.isOAuthEnabled else {
            self.authErrorMessage = "Nextendo OAuth is disabled because this build was compiled without OAuth credentials."
            return
        }
        let pkce = PKCE.generate()
        self.currentCodeVerifier = pkce.verifier
        self.currentOAuthState = pkce.state
        let rawBase = nextendoServerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseUrl = rawBase.isEmpty ? NextendoSecrets.defaultServerUrl : rawBase
        let redirectUri = NextendoSecrets.defaultRedirectUri
        let clientId = NextendoSecrets.oauthClientId
        
        var components = URLComponents(string: "\(baseUrl)/api/oauth/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: NextendoSecrets.oauthScopes),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        
        guard let authUrl = components?.url else {
            self.authErrorMessage = "Invalid authorization URL configuration."
            return
        }
        
        self.currentAuthUrl = authUrl
        self.isAuthenticating = true
        self.showingFullPageOAuth = true
    }
    
    private func parseOAuthCallback(url: URL, codeVerifier: String, redirectUri: String, baseUrl: String, clientId: String) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            self.authErrorMessage = "Invalid authorization callback received."
            return
        }
        
        var code: String? = nil
        var errorStr: String? = nil
        
        if let queryItems = components.queryItems {
            for item in queryItems {
                if item.name == "code" { code = item.value }
                if item.name == "error" || item.name == "error_description" { errorStr = item.value }
                if (item.name == "access_token" || item.name == "nex_token"), let val = item.value, !val.isEmpty {
                    self.handleReceivedToken(token: val, baseUrl: baseUrl)
                    return
                }
            }
        }
        
        if let errorStr = errorStr {
            self.authErrorMessage = "Authorization failed: \(errorStr)"
            return
        }
        
        guard let authCode = code, !authCode.isEmpty else {
            self.authErrorMessage = "No authorization code returned."
            return
        }
        
        self.exchangeCodeForToken(code: authCode, codeVerifier: codeVerifier, redirectUri: redirectUri, baseUrl: baseUrl, clientId: clientId)
    }
    
    private func exchangeCodeForToken(code: String, codeVerifier: String, redirectUri: String, baseUrl: String, clientId: String) {
        guard let tokenUrl = URL(string: "\(baseUrl)/api/oauth/token") else {
            self.authErrorMessage = "Invalid token endpoint URL."
            return
        }
        
        var request = URLRequest(url: tokenUrl)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let bodyComponents = [
            "grant_type": "authorization_code",
            "client_id": clientId,
            "code": code,
            "redirect_uri": redirectUri,
            "code_verifier": codeVerifier
        ]
        
        let bodyString = bodyComponents.map {
            let key = $0.key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.key
            let val = $0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value
            return "\(key)=\(val)"
        }.joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)
        
        self.isAuthenticating = true
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                self.isAuthenticating = false
                
                if let error = error {
                    self.authErrorMessage = "Token exchange failed: \(error.localizedDescription)"
                    return
                }
                
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.authErrorMessage = "Invalid response from Nextendo server."
                    return
                }
                
                if let errorMsg = (json["error_description"] as? String) ?? (json["error"] as? String) {
                    self.authErrorMessage = "Authorization error: \(errorMsg)"
                    return
                }
                
                let token = (json["access_token"] as? String) ?? (json["nex_token"] as? String)
                guard let validToken = token, !validToken.isEmpty else {
                    self.authErrorMessage = "Could not retrieve access token."
                    return
                }
                
                self.handleReceivedToken(token: validToken, baseUrl: baseUrl, initialJson: json)
            }
        }.resume()
    }
    
    private func handleReceivedToken(token: String, baseUrl: String, initialJson: [String: Any]? = nil) {
        NextendoKeychainHelper.saveToken(token)
        self.nextendoAuthToken = token
        
        var inlineUsername = ""
        var inlineFriendCode = ""
        var inlinePid: UInt64 = 0
        
        if let initialJson = initialJson {
            let userDict = (initialJson["user"] as? [String: Any]) ?? (initialJson["account"] as? [String: Any])
            if let userDict = userDict {
                inlineUsername = (userDict["username"] as? String) ?? ""
                inlineFriendCode = (userDict["friend_code"] as? String) ?? ""
                if let pidNum = userDict["pid"] as? UInt64 {
                    inlinePid = pidNum
                } else if let pidInt = userDict["pid"] as? Int {
                    inlinePid = UInt64(pidInt)
                } else if let pidStr = userDict["pid"] as? String, let parsed = UInt64(pidStr) {
                    inlinePid = parsed
                }
            }
        }
        
        self.fetchUserInfoAndSync(token: token, baseUrl: baseUrl, fallbackUsername: inlineUsername, fallbackFriendCode: inlineFriendCode, fallbackPid: inlinePid)
    }
    
    private func fetchUserInfoAndSync(token: String, baseUrl: String, fallbackUsername: String, fallbackFriendCode: String, fallbackPid: UInt64) {
        guard let userinfoUrl = URL(string: "\(baseUrl)/api/oauth/userinfo") else {
            self.finalizeProfileSync(name: fallbackUsername.isEmpty ? "Nextendo" : fallbackUsername, token: token, baseUrl: baseUrl, pid: fallbackPid, friendCode: fallbackFriendCode, avatarData: nil, miiData: "")
            return
        }
        
        var request = URLRequest(url: userinfoUrl)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        self.isAuthenticating = true
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            let httpResponse = response as? HTTPURLResponse
            let isUserinfoOk = (httpResponse?.statusCode ?? 500) >= 200 && (httpResponse?.statusCode ?? 500) < 300
            
            if isUserinfoOk, let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.processUserData(dict: json, token: token, baseUrl: baseUrl, fallbackUsername: fallbackUsername, fallbackFriendCode: fallbackFriendCode, fallbackPid: fallbackPid)
            } else {
                self.fetchProfileFallback(token: token, baseUrl: baseUrl, fallbackUsername: fallbackUsername, fallbackFriendCode: fallbackFriendCode, fallbackPid: fallbackPid)
            }
        }.resume()
    }
    
    private func fetchProfileFallback(token: String, baseUrl: String, fallbackUsername: String, fallbackFriendCode: String, fallbackPid: UInt64) {
        guard let profileUrl = URL(string: "\(baseUrl)/api/profile") else {
            DispatchQueue.main.async {
                self.isAuthenticating = false
                self.finalizeProfileSync(name: fallbackUsername.isEmpty ? "Nextendo" : fallbackUsername, token: token, baseUrl: baseUrl, pid: fallbackPid, friendCode: fallbackFriendCode, avatarData: nil, miiData: "")
            }
            return
        }
        
        var request = URLRequest(url: profileUrl)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let dict = (json["profile"] as? [String: Any]) ?? json
                self.processUserData(dict: dict, token: token, baseUrl: baseUrl, fallbackUsername: fallbackUsername, fallbackFriendCode: fallbackFriendCode, fallbackPid: fallbackPid)
            } else {
                DispatchQueue.main.async {
                    self.isAuthenticating = false
                    self.finalizeProfileSync(name: fallbackUsername.isEmpty ? "Nextendo" : fallbackUsername, token: token, baseUrl: baseUrl, pid: fallbackPid, friendCode: fallbackFriendCode, avatarData: nil, miiData: "")
                }
            }
        }.resume()
    }
    
    private func processUserData(dict: [String: Any], token: String, baseUrl: String, fallbackUsername: String, fallbackFriendCode: String, fallbackPid: UInt64) {
        var profileName = fallbackUsername
        if let name = (dict["username"] as? String) ?? (dict["name"] as? String) ?? (dict["pseudo"] as? String), !name.isEmpty {
            profileName = name
        }
        
        var finalPid = fallbackPid
        if let pidNum = dict["pid"] as? UInt64 {
            finalPid = pidNum
        } else if let pidInt = dict["pid"] as? Int {
            finalPid = UInt64(pidInt)
        } else if let pidStr = dict["pid"] as? String, let parsed = UInt64(pidStr) {
            finalPid = parsed
        }
        
        var finalFriendCode = fallbackFriendCode
        if let fc = (dict["friend_code"] as? String) ?? (dict["friendCode"] as? String), !fc.isEmpty {
            finalFriendCode = fc
        }
        
        var finalMiiB64 = ""
        if let mii = dict["mii"] as? String, !mii.isEmpty {
            finalMiiB64 = mii
        }
        
        var avatarUrlStr: String? = nil
        if let aUrl = (dict["avatar_url"] as? String) ?? (dict["avatar"] as? String) ?? (dict["icon_url"] as? String), !aUrl.isEmpty {
            avatarUrlStr = aUrl
        }
        
        var avatarData: Data? = nil
        if let imageB64 = dict["image"] as? String, let decoded = Data(base64Encoded: imageB64) {
            avatarData = decoded
        }
        
        if let avatarUrlStr = avatarUrlStr {
            let fullAvatarUrl: URL?
            if avatarUrlStr.hasPrefix("http://") || avatarUrlStr.hasPrefix("https://") {
                fullAvatarUrl = URL(string: avatarUrlStr)
            } else if avatarUrlStr.hasPrefix("/") {
                fullAvatarUrl = URL(string: "\(baseUrl)\(avatarUrlStr)")
            } else {
                fullAvatarUrl = URL(string: "\(baseUrl)/\(avatarUrlStr)")
            }
            
            if let fullAvatarUrl = fullAvatarUrl {
                URLSession.shared.dataTask(with: fullAvatarUrl) { data, _, _ in
                    DispatchQueue.main.async {
                        self.isAuthenticating = false
                        let finalAvatar = data ?? avatarData
                        self.finalizeProfileSync(name: profileName.isEmpty ? "Nextendo" : profileName, token: token, baseUrl: baseUrl, pid: finalPid, friendCode: finalFriendCode, avatarData: finalAvatar, miiData: finalMiiB64)
                    }
                }.resume()
                return
            }
        }
        
        DispatchQueue.main.async {
            self.isAuthenticating = false
            self.finalizeProfileSync(name: profileName.isEmpty ? "Nextendo" : profileName, token: token, baseUrl: baseUrl, pid: finalPid, friendCode: finalFriendCode, avatarData: avatarData, miiData: finalMiiB64)
        }
    }
    
    private func finalizeProfileSync(name: String, token: String, baseUrl: String, pid: UInt64, friendCode: String, avatarData: Data?, miiData: String) {
        if pid != 0 {
            self.nextendoPid = String(pid)
        }
        if !name.isEmpty {
            self.nextendoUserPseudo = name
        }
        if !friendCode.isEmpty {
            self.nextendoFriendCode = friendCode
        }
        if !miiData.isEmpty {
            UserDefaults.standard.set(miiData, forKey: "nextendoMiiData")
            if let miiBytes = Data(base64Encoded: miiData) {
                Ryujinx.injectNextendoMii(data: miiBytes)
            }
        }
        
        let profilePath = URL.documentsDirectory.appendingPathComponent("system").appendingPathComponent("Profiles.json")
        let finalImageData = avatarData ?? self.generateDefaultAvatar(name: name)
        self.applyProfileToRyujinx(name: name, imageData: finalImageData, profilePath: profilePath, pid: pid, nexToken: token, friendCode: friendCode, miiData: miiData)
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
