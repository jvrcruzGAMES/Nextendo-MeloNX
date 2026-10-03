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
    
    // Account & Profile Display (Persisted in Keychain, cached in UserDefaults for UI display)
    @AppStorage("nextendoUserPseudo") private var nextendoUserPseudo: String = ""
    @AppStorage("nextendoFriendCode") private var nextendoFriendCode: String = ""
    @AppStorage("nextendoPid") private var nextendoPid: String = "0"
    @AppStorage("nextendoAuthToken") private var nextendoAuthToken: String = ""
    
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
    @State private var isSyncingProfile = false
    @State private var profileAvatarImage: UIImage? = nil
    @State private var showingFullPageOAuth = false
    @State private var currentAuthUrl: URL? = nil
    @State private var currentCodeVerifier: String = ""
    @State private var currentOAuthState: String = ""
    @State private var showingCredentialsLogin = false
    @State private var loginUsername = ""
    @State private var loginPassword = ""
    @State private var loginErrorMessage: String? = nil
    @State private var isLoggingInWithCreds = false
    
    @State private var isSupportedGamesExpanded = false
    @State private var hasValidNexToken = false
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
            
            // Section 2: Account & Profile (Stored securely in Keychain)
            Section(header: Text("Account & Profile")) {
                if nextendoAuthToken.isEmpty && (nextendoPid == "0" || nextendoPid.isEmpty) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Not Connected")
                                .font(.subheadline.weight(.semibold))
                        }
                        Text("Nextendo Network requires an authenticated account to participate in online matchmaking and multiplayer in supported games (Mario Kart 8 Deluxe, Splatoon, Pokémon, etc.).")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                    
                    Button(action: {
                        loginErrorMessage = nil
                        showingCredentialsLogin = true
                    }) {
                        HStack {
                            Label("Sign In with Nextendo Account", systemImage: "person.crop.circle.badge.checkmark")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Link(destination: URL(string: "https://nextendo.network/register")!) {
                        HStack {
                            Label("Create Nextendo Account", systemImage: "person.badge.plus")
                                .font(.subheadline)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                        HStack(spacing: 14) {
                            if let avatar = profileAvatarImage {
                                Image(uiImage: avatar)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 54, height: 54)
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(Color.blue, lineWidth: 2))
                            } else {
                                ZStack {
                                    Circle()
                                        .fill(Color.blue.opacity(0.15))
                                        .frame(width: 54, height: 54)
                                    Image(systemName: "person.crop.circle.fill")
                                        .font(.system(size: 42))
                                        .foregroundColor(.blue)
                                }
                            }
                            
                            VStack(alignment: .leading, spacing: 3) {
                                Text(nextendoUserPseudo.isEmpty ? "Connected Player" : nextendoUserPseudo)
                                    .font(.headline)
                                Text(nextendoFriendCode.isEmpty ? "PID: \(nextendoPid)" : nextendoFriendCode)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        
                        if hasValidNexToken {
                            HStack {
                                Text("NEX Multiplayer")
                                    .font(.subheadline)
                                Spacer()
                                HStack(spacing: 5) {
                                    Image(systemName: "checkmark.shield.fill")
                                        .foregroundColor(.green)
                                    Text("Active (HMAC Ready)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(.green)
                                }
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                    Text("NEX Token Missing")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(.orange)
                                }
                                Text("Games requiring NEX authentication (Mario Kart 8 Deluxe, Splatoon 2, etc.) need a valid HMAC token. Without it, connection fails with error 2306-0802.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Button(action: {
                                    loginErrorMessage = nil
                                    showingCredentialsLogin = true
                                }) {
                                    Label("Re-authenticate Now", systemImage: "arrow.clockwise.circle.fill")
                                        .font(.subheadline.weight(.medium))
                                }
                                .padding(.top, 2)
                            }
                            .padding(.vertical, 4)
                        }
                        
                        Button(action: {
                            syncProfileNow()
                        }) {
                            HStack {
                                Label("Sync Profile & Picture", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.subheadline)
                                Spacer()
                                if isSyncingProfile {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                }
                            }
                        }
                        .disabled(isSyncingProfile)
                        
                        HStack {
                            Text("Status")
                                .font(.subheadline)
                            Spacer()
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 8, height: 8)
                                Text("Connected")
                                    .font(.subheadline)
                                    .foregroundColor(.green)
                            }
                        }
                        
                        HStack {
                            Text("Display Name")
                                .font(.subheadline)
                            Spacer()
                            Text(nextendoUserPseudo.isEmpty ? "Connected Player" : nextendoUserPseudo)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .contextMenu {
                            Button(action: {
                                UIPasteboard.general.string = nextendoUserPseudo
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
                                UIPasteboard.general.string = nextendoFriendCode
                            }) {
                                Label("Copy Friend Code", systemImage: "doc.on.doc")
                            }
                        }
                        
                        HStack {
                            Text("Network ID (PID)")
                                .font(.subheadline)
                            Spacer()
                            Text(nextendoPid == "0" ? "Unknown" : nextendoPid)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        Link(destination: URL(string: "\(nextendoServerUrl.isEmpty ? NextendoSecrets.defaultServerUrl : nextendoServerUrl)/compte") ?? URL(string: "https://nextendo.network/compte")!) {
                            HStack {
                                Label("Change Account Settings", systemImage: "arrow.up.right.square")
                                    .font(.subheadline)
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Button(role: .destructive, action: {
                            NextendoProfileHelper.shared.removeNextendoProfileOnSignOut()
                            NextendoKeychainHelper.clearAllCredentials()
                            nextendoAuthToken = ""
                            nextendoUserPseudo = ""
                            nextendoFriendCode = ""
                            nextendoPid = "0"
                            hasValidNexToken = false
                            UserDefaults.standard.removeObject(forKey: "nextendoAuthToken")
                            UserDefaults.standard.removeObject(forKey: "nextendoNexToken")
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
                                            .font(.subheadline.weight(.semibold))
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
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NextendoProfileUpdated"))) { _ in
            self.refreshAccountState()
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
        .sheet(isPresented: $showingCredentialsLogin) {
            NavigationStack {
                Form {
                    Section {
                        VStack(alignment: .center, spacing: 8) {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .font(.system(size: 44))
                                .foregroundColor(.blue)
                            Text("Nextendo Sign In")
                                .font(.headline)
                            Text("Enter your Nextendo username or email and password. This configures your profile and obtains your authentic NEX HMAC token for online multiplayer.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    
                    Section(header: Text("Account Credentials")) {
                        TextField("Username or Email", text: $loginUsername)
                            .textContentType(.username)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .keyboardType(.emailAddress)
                        
                        SecureField("Password", text: $loginPassword)
                            .textContentType(.password)
                    }
                    
                    if let error = loginErrorMessage {
                        Section {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                    
                    Section {
                        Button(action: {
                            submitCredentialsLogin()
                        }) {
                            HStack {
                                Spacer()
                                if isLoggingInWithCreds {
                                    ProgressView()
                                        .padding(.trailing, 4)
                                }
                                Text(isLoggingInWithCreds ? "Signing In..." : "Sign In")
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                        }
                        .disabled(loginUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loginPassword.isEmpty || isLoggingInWithCreds)
                    }
                    
                    Section {
                        Link(destination: URL(string: "https://nextendo.network/register")!) {
                            HStack {
                                Label("Create Nextendo Account", systemImage: "person.badge.plus")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .navigationTitle("Sign In")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            showingCredentialsLogin = false
                            loginPassword = ""
                            loginErrorMessage = nil
                        }
                        .disabled(isLoggingInWithCreds)
                    }
                }
            }
        }
        .onAppear {
            self.refreshAccountState()
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
                NextendoProfileHelper.shared.removeNextendoProfileOnSignOut()
                NextendoKeychainHelper.clearAllCredentials()
                UserDefaults.standard.removeObject(forKey: "nextendoAuthToken")
                nextendoAuthToken = ""
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
            URLQueryItem(name: "app", value: "ryujinx"),
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
        var accessToken: String? = nil
        var nexToken: String? = nil
        
        if let queryItems = components.queryItems {
            for item in queryItems {
                if item.name == "code" { code = item.value }
                if item.name == "error" || item.name == "error_description" { errorStr = item.value }
                if item.name == "access_token" { accessToken = item.value }
                if item.name == "nex_token" { nexToken = item.value }
            }
        }
        
        if let access = accessToken, !access.isEmpty {
            self.handleReceivedToken(authToken: access, nexToken: nexToken ?? "", baseUrl: baseUrl)
            return
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
                
                let accessToken = (json["access_token"] as? String) ?? ""
                let nexToken = (json["nex_token"] as? String) ?? ""
                let effectiveAuth = !accessToken.isEmpty ? accessToken : nexToken
                let effectiveNex = nexToken
                
                guard !effectiveAuth.isEmpty else {
                    self.authErrorMessage = "Could not retrieve access token."
                    return
                }
                
                self.handleReceivedToken(authToken: effectiveAuth, nexToken: effectiveNex, baseUrl: baseUrl, initialJson: json)
            }
        }.resume()
    }
    
    private func handleReceivedToken(authToken: String, nexToken: String, baseUrl: String, initialJson: [String: Any]? = nil) {
        var inlineUsername = ""
        var inlineFriendCode = ""
        var inlinePid: UInt64 = 0
        var inlineMii = ""
        
        if let initialJson = initialJson {
            let userDict = (initialJson["account"] as? [String: Any]) ?? (initialJson["user"] as? [String: Any])
            if let userDict = userDict {
                inlineUsername = (userDict["username"] as? String) ?? ""
                inlineFriendCode = (userDict["friend_code"] as? String) ?? ""
                if let mii = userDict["mii"] as? String { inlineMii = mii }
                if let pidNum = userDict["pid"] as? UInt64 {
                    inlinePid = pidNum
                } else if let pidInt = userDict["pid"] as? Int {
                    inlinePid = UInt64(pidInt)
                } else if let pidStr = userDict["pid"] as? String, let parsed = UInt64(pidStr) {
                    inlinePid = parsed
                }
            }
        }
        
        self.isAuthenticating = true
        NextendoProfileHelper.shared.fetchAndSyncProfile(
            authToken: authToken,
            nexToken: nexToken,
            baseUrl: baseUrl,
            fallbackPid: inlinePid,
            fallbackUsername: inlineUsername,
            fallbackFriendCode: inlineFriendCode,
            fallbackMii: inlineMii
        ) { success, _ in
            DispatchQueue.main.async {
                self.isAuthenticating = false
                self.refreshAccountState()
            }
        }
    }



    private func submitCredentialsLogin() {
        let rawBase = nextendoServerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseUrl = rawBase.isEmpty ? NextendoSecrets.defaultServerUrl : rawBase
        loginErrorMessage = nil
        isLoggingInWithCreds = true
        
        NextendoProfileHelper.shared.loginWithCredentials(
            login: loginUsername,
            password: loginPassword,
            baseUrl: baseUrl
        ) { success, error in
            DispatchQueue.main.async {
                self.isLoggingInWithCreds = false
                if success {
                    self.showingCredentialsLogin = false
                    self.loginPassword = ""
                    self.loginErrorMessage = nil
                    self.refreshAccountState()
                } else {
                    self.loginErrorMessage = error ?? "Failed to sign in. Please verify your credentials."
                }
            }
        }
    }

    private func refreshAccountState() {
        if let creds = NextendoKeychainHelper.loadCredentials() {
            if !creds.authToken.isEmpty {
                nextendoAuthToken = creds.authToken
            } else if !creds.token.isEmpty {
                nextendoAuthToken = creds.token
            }
            if !creds.pid.isEmpty && creds.pid != "0" {
                nextendoPid = creds.pid
            }
            if !creds.username.isEmpty {
                nextendoUserPseudo = creds.username
            }
            if !creds.friendCode.isEmpty {
                nextendoFriendCode = creds.friendCode
            }
            self.hasValidNexToken = !creds.nexToken.isEmpty
        } else if let savedToken = UserDefaults.standard.string(forKey: "nextendoAuthToken"), !savedToken.isEmpty {
            nextendoAuthToken = savedToken
            self.hasValidNexToken = false
        } else {
            self.hasValidNexToken = false
        }
        self.loadActiveAvatar()
    }

    private func syncProfileNow() {
        self.isSyncingProfile = true
        NextendoProfileHelper.shared.syncCurrentSavedAccount { success, errorMsg in
            DispatchQueue.main.async {
                self.isSyncingProfile = false
                if success {
                    self.refreshAccountState()
                } else if let errorMsg = errorMsg {
                    self.authErrorMessage = errorMsg
                }
            }
        }
    }

    private func loadActiveAvatar() {
        let profilePath = NextendoProfileHelper.profilePath
        if let data = try? Data(contentsOf: profilePath),
           let profiles = try? JSONDecoder().decode(Profiles.self, from: data) {
            let targetUser = profiles.profiles.first(where: { $0.user_id == profiles.last_opened }) ??
                             profiles.profiles.first(where: { $0.name.lowercased() == self.nextendoUserPseudo.lowercased() })
            if let targetUser = targetUser,
               let imageB64 = targetUser.image,
               let imgData = Data(base64Encoded: imageB64),
               let img = UIImage(data: imgData) {
                self.profileAvatarImage = img
                return
            }
        }
        
        if let pidNum = UInt64(nextendoPid), pidNum != 0 {
            NextendoProfileHelper.shared.fetchAvatar(pid: pidNum, avatarUrlStr: nil, baseUrl: nextendoServerUrl) { imgData in
                if let imgData = imgData, let img = UIImage(data: imgData) {
                    DispatchQueue.main.async {
                        self.profileAvatarImage = img
                    }
                }
            }
        }
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
