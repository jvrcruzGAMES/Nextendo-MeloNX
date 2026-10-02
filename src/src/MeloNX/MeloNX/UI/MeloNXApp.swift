//
//  MeloNXApp.swift
//  MeloNX
//
//  Created by Stossy11 on 4/4/2026.
//

import SwiftUI
import SDL3
import AVFoundation

func configureAudioSession() {
    do {
        let session = AVAudioSession.sharedInstance()

        try session.setCategory(
            .playback,
            options: .mixWithOthers
        )
        try session.setPreferredSampleRate(48000)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
    } catch {
        print("Audio session error: \(error.localizedDescription)")
    }
}

var environment: [EnvironmentVariable] = [
    EnvironmentVariable(string: "MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS", value: "0"),
    EnvironmentVariable(string: "MVK_CONFIG_MAX_ACTIVE_METAL_COMMAND_BUFFERS_PER_QUEUE", value: "32"),
]


func initEnvironmentVariables(reloadAccount: Bool = true) {
    let defaults = UserDefaults.standard
    
    let enableNextendo = defaults.object(forKey: "enableNextendoOnline") as? Bool ?? true
    let enableServerOverride = defaults.bool(forKey: "enableServerOverride")
    
    // Custom Server Override Settings (User-defined, completely independent of Nextendo mode)
    let customServerUrl = defaults.string(forKey: "customServerUrl")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let customServerIp = defaults.string(forKey: "customServerIp")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let customNatIp = defaults.string(forKey: "customNatIp")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    
    // Clean up any legacy shared keys
    if defaults.object(forKey: "nextendoServerIp") != nil {
        defaults.removeObject(forKey: "nextendoServerIp")
    }
    if defaults.object(forKey: "nextendoNatIp") != nil {
        defaults.removeObject(forKey: "nextendoNatIp")
    }
    
    // Nextendo Mode Settings (Uses secret Nextendo build constants)
    let nextendoServerUrl = defaults.string(forKey: "nextendoServerUrl") ?? NextendoSecrets.defaultServerUrl
    let nextendoEffectiveServerUrl = nextendoServerUrl.isEmpty ? NextendoSecrets.defaultServerUrl : nextendoServerUrl
    let nextendoEffectiveServerIp = NextendoSecrets.defaultServerIp.isEmpty ? "127.0.0.1" : NextendoSecrets.defaultServerIp
    let nextendoEffectiveNatIp = NextendoSecrets.defaultNatIp.isEmpty ? "127.0.0.1" : NextendoSecrets.defaultNatIp
    
    let keychainToken = NextendoKeychainHelper.loadToken()
    let nexToken: String = {
        guard NextendoSecrets.isOAuthEnabled else {
            return ""
        }
        if let token = keychainToken, !token.isEmpty {
            return token
        }
        let fallback = defaults.string(forKey: "nextendoAuthToken") ?? ""
        if !fallback.isEmpty {
            NextendoKeychainHelper.saveToken(fallback)
        }
        return fallback
    }()
    
    // Base environment variables
    for env in environment { env.set() }
    
    if enableServerOverride {
        // Custom Server Mode: Uses IPs defined by the user in Custom server override, ignoring build constants
        let effectiveCustomIp = customServerIp.isEmpty ? "127.0.0.1" : customServerIp
        let effectiveCustomNatIp = customNatIp.isEmpty ? effectiveCustomIp : customNatIp
        let effectiveCustomUrl = customServerUrl.isEmpty ? "http://\(effectiveCustomIp)" : customServerUrl
        
        setenv("NEXTENDO_SERVER_IP", effectiveCustomIp, 1)
        setenv("NEXTENDO_NAT_IP", effectiveCustomNatIp, 1)
        setenv("NEXTENDO_API", effectiveCustomUrl, 1)
        setenv("NEXTENDO_HORS_NEXTENDO", "1", 1)
        unsetenv("NEXTENDO_SITE")
        unsetenv("NEXTENDO_TOKEN")
    } else if enableNextendo {
        // Nextendo Network Mode: Uses secret Nextendo IPs from build constants
        setenv("NEXTENDO_SERVER_IP", nextendoEffectiveServerIp, 1)
        setenv("NEXTENDO_NAT_IP", nextendoEffectiveNatIp, 1)
        setenv("NEXTENDO_API", nextendoEffectiveServerUrl, 1)
        setenv("NEXTENDO_SITE", "https://nextendo.network", 1)
        setenv("NEXTENDO_NPLN_DELAY_MS", "3000", 1)
        unsetenv("NEXTENDO_HORS_NEXTENDO")
        
        if !nexToken.isEmpty {
            setenv("NEXTENDO_TOKEN", nexToken, 1)
            
            let accountFilePath = URL.documentsDirectory.appendingPathComponent("nextendo_account.txt")
            let pid = defaults.string(forKey: "nextendoPid") ?? "0"
            let username = defaults.string(forKey: "nextendoUserPseudo") ?? ""
            let friendCode = defaults.string(forKey: "nextendoFriendCode") ?? ""
            let miiData = defaults.string(forKey: "nextendoMiiData") ?? ""
            
            var profileUserId = ""
            let profilePath = URL.documentsDirectory.appendingPathComponent("system").appendingPathComponent("Profiles.json")
            if let data = try? Data(contentsOf: profilePath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let lastOpened = json["last_opened"] as? String {
                profileUserId = lastOpened.replacingOccurrences(of: "-", with: "")
            }
            
            let content = """
            pid=\(pid)
            username=\(username)
            friend_code=\(friendCode)
            nex_token=\(nexToken)
            profile_user_id=\(profileUserId)
            mii_data=\(miiData)
            is_guest=0
            """
            try? content.write(to: accountFilePath, atomically: true, encoding: .utf8)
        } else {
            unsetenv("NEXTENDO_TOKEN")
        }
    } else {
        unsetenv("NEXTENDO_SERVER_IP")
        unsetenv("NEXTENDO_NAT_IP")
        unsetenv("NEXTENDO_API")
        unsetenv("NEXTENDO_SITE")
        unsetenv("NEXTENDO_TOKEN")
        unsetenv("NEXTENDO_HORS_NEXTENDO")
    }
    
    if defaults.bool(forKey: "enableNsoDump") {
        setenv("NEXTENDO_DUMP_NSO", "1", 1)
    } else {
        unsetenv("NEXTENDO_DUMP_NSO")
    }
    
    if let device = MTLCreateSystemDefaultDevice(), device.argumentBuffersSupport.rawValue < MTLArgumentBuffersTier.tier2.rawValue {
        setenv("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", "0", 1)
    }
    
    if #available(iOS 19, *) {
        setenv("HAS_TXM", ProcessInfo.processInfo.hasTXM && !ProcessInfo.processInfo.isiOSAppOnMac ? "1" : "0", 1)
        setenv("DUAL_MAPPED_JIT", !ProcessInfo.processInfo.isiOSAppOnMac ? "1" : "0", 1)
    } else {
        setenv("HAS_TXM", "0", 1)
        setenv("DUAL_MAPPED_JIT", "0", 1)
    }
    
    if reloadAccount {
        Ryujinx.reloadNextendoAccount()
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock = UIInterfaceOrientationMask.all

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return AppDelegate.orientationLock
    }
}


@main
struct MeloNXApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    @StateObject var ryujinxController: RyujinxController = .shared
    @StateObject var themeManager: ThemeManager = .shared
    
    @AppStorage("hasSetupFinished") var hasSetupFinished: Bool = false
    @AppStorage("lastAppversion") var lastAppversion: Data = Data()
    
    init() {
        SDL_SetMainReady()
        SDL_SetiOSEventPump(true)
        SDL_Init(SDL_INIT_EVENTS)
        JIT26BreakpointHandler()
        initEnvironmentVariables(reloadAccount: false)
        Ryujinx.initialize()
        Ryujinx.reloadNextendoAccount()
        RyujinxController.shared.loadConfig()
        ThemeManager.shared.applyUIKitAppearance()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ryujinxController)
                .environmentObject(themeManager)
                .withAppTheme()
                .onAppear() {
                    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                    
                    configureAudioSession()
                    
                    let versionNumber: Float = lastAppversion.count >= MemoryLayout<Float>.size ? lastAppversion.withUnsafeBytes { buffer in
                        guard let base = buffer.baseAddress else { return 0.0 }
                        return safeLoad(base, as: Float.self)
                    } : 0.0
                    let currentVersion = Float(Bundle.main.versionNumber) ?? .zero
                    
                    if versionNumber < currentVersion {
                        lastAppversion = encodeFloatToData(currentVersion)
                        hasSetupFinished = false
                    }
                }
                .sheet(isPresented: .constant(!hasSetupFinished)) {
                    SetupView {
                        hasSetupFinished = true
                        ryujinxController.loadGames()
                    }
                    .interactiveDismissDisabled()
                    .withAppTheme()
                }
        }
    }
    
    func encodeFloatToData(_ value: Float) -> Data {
        var mutableValue = value
        return Data(bytes: &mutableValue, count: MemoryLayout<Float>.size)
    }
}
