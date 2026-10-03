//
//  NextendoProfileHelper.swift
//  MeloNX
//
//  Helper for retrieving Nextendo profile information (username, PID, friend code,
//  Mii, avatar/profile picture) from Nextendo REST APIs, and synchronizing with
//  MeloNX's Profile Manager (system/Profiles.json) and Ryujinx.
//

import Foundation
import UIKit
import CommonCrypto

public struct NexTokenResult {
    public let nexToken: String
    public let pid: UInt64
    public let username: String
    public let friendCode: String
    
    public init(nexToken: String, pid: UInt64, username: String, friendCode: String) {
        self.nexToken = nexToken
        self.pid = pid
        self.username = username
        self.friendCode = friendCode
    }
}


public struct NextendoUserInfo {
    public var pid: UInt64
    public var username: String
    public var friendCode: String
    public var avatarUrl: String?
    public var miiData: String?
    
    public init(pid: UInt64, username: String, friendCode: String, avatarUrl: String? = nil, miiData: String? = nil) {
        self.pid = pid
        self.username = username
        self.friendCode = friendCode
        self.avatarUrl = avatarUrl
        self.miiData = miiData
    }
}

public final class NextendoProfileHelper {
    public static let shared = NextendoProfileHelper()
    
    public static var profilePath: URL {
        URL.documentsDirectory.appendingPathComponent("system").appendingPathComponent("Profiles.json")
    }
    
    public static var accountFilePath: URL {
        URL.documentsDirectory.appendingPathComponent("nextendo_account.txt")
    }
    
    private let avatarCache = NSCache<NSString, UIImage>()
    
    private init() {}
    
    // MARK: - Server URL Resolution
    
    public static func resolveBaseUrl() -> String {
        let saved = UserDefaults.standard.string(forKey: "nextendoServerUrl")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? NextendoSecrets.defaultServerUrl : saved
    }
    
    // MARK: - Direct Credential Login (/api/login matching Ryujinx-Nextendo)
    
    /// Authenticates directly with Nextendo credentials (email/username and password),
    /// obtaining the account identity, persistent PID, session token, and NEX token.
    public func loginWithCredentials(
        login: String,
        password: String,
        baseUrl: String = NextendoProfileHelper.resolveBaseUrl(),
        completion: @escaping (Bool, String?) -> Void
    ) {
        let trimmedLogin = login.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmedLogin.isEmpty && !trimmedPassword.isEmpty else {
            completion(false, "Login and password cannot be empty.")
            return
        }
        
        guard let url = URL(string: "\(baseUrl)/api/login") else {
            completion(false, "Invalid login URL.")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(NextendoSecrets.oauthClientId, forHTTPHeaderField: "X-Nextendo-Client-Id")
        request.timeoutInterval = 60.0
        
        let payload: [String: String] = ["login": trimmedLogin, "password": trimmedPassword]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                DispatchQueue.main.async { completion(false, error.localizedDescription) }
                return
            }
            
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { completion(false, "Invalid response from server.") }
                return
            }
            
            let httpResponse = response as? HTTPURLResponse
            if let httpResponse = httpResponse, httpResponse.statusCode != 200 {
                let err = (json["error"] as? String) ?? (json["message"] as? String) ?? "Invalid credentials."
                DispatchQueue.main.async { completion(false, err) }
                return
            }
            
            guard let acct = json["account"] as? [String: Any] else {
                let err = (json["error"] as? String) ?? "No account data returned."
                DispatchQueue.main.async { completion(false, err) }
                return
            }
            
            var pid: UInt64 = 0
            if let pNum = acct["pid"] as? UInt64 {
                pid = pNum
            } else if let pInt = acct["pid"] as? Int {
                pid = UInt64(pInt)
            } else if let pStr = acct["pid"] as? String, let p = UInt64(pStr) {
                pid = p
            }
            
            let username = (acct["username"] as? String) ?? trimmedLogin
            let friendCode = (acct["friend_code"] as? String) ?? ""
            let nexToken = (json["nex_token"] as? String) ?? ""
            let sessionToken = (json["token"] as? String) ?? ""
            
            guard !nexToken.isEmpty else {
                DispatchQueue.main.async { completion(false, "Server did not return a valid NEX token.") }
                return
            }
            
            self.fetchAndSyncProfile(
                authToken: sessionToken,
                nexToken: nexToken,
                baseUrl: baseUrl,
                fallbackPid: pid,
                fallbackUsername: username,
                fallbackFriendCode: friendCode
            ) { success, _ in
                DispatchQueue.main.async {
                    completion(success, success ? nil : "Failed to sync profile.")
                }
            }
        }.resume()
    }
    
    // MARK: - Fetch Profile Info
    
    /// Queries Nextendo user endpoints (/api/oauth/userinfo, /api/profile?user={pid}, or /api/profile)
    /// to get the most up-to-date player identity and avatar URL.
    public func fetchUserInfo(
        authToken: String,
        baseUrl: String = NextendoProfileHelper.resolveBaseUrl(),
        fallbackPid: UInt64 = 0,
        fallbackUsername: String = "",
        fallbackFriendCode: String = "",
        completion: @escaping (Result<NextendoUserInfo, Error>) -> Void
    ) {
        guard let userinfoUrl = URL(string: "\(baseUrl)/api/oauth/userinfo") else {
            completion(.failure(URLError(.badURL)))
            return
        }
        
        var request = URLRequest(url: userinfoUrl)
        request.httpMethod = "GET"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue(NextendoSecrets.oauthClientId, forHTTPHeaderField: "X-Nextendo-Client-Id")
        request.timeoutInterval = 45.0
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 500
            
            if statusCode >= 200 && statusCode < 300, let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let info = self.parseUserInfo(dict: json, fallbackPid: fallbackPid, fallbackUsername: fallbackUsername, fallbackFriendCode: fallbackFriendCode)
                completion(.success(info))
            } else {
                // Fallback to /api/profile?user={pid} or /api/profile
                self.fetchProfileFallback(
                    authToken: authToken,
                    baseUrl: baseUrl,
                    fallbackPid: fallbackPid,
                    fallbackUsername: fallbackUsername,
                    fallbackFriendCode: fallbackFriendCode,
                    completion: completion
                )
            }
        }.resume()
    }
    
    private func fetchProfileFallback(
        authToken: String,
        baseUrl: String,
        fallbackPid: UInt64,
        fallbackUsername: String,
        fallbackFriendCode: String,
        completion: @escaping (Result<NextendoUserInfo, Error>) -> Void
    ) {
        let endpoint: String
        if fallbackPid != 0 {
            endpoint = "\(baseUrl)/api/profile?user=\(fallbackPid)"
        } else {
            endpoint = "\(baseUrl)/api/profile"
        }
        
        guard let url = URL(string: endpoint) else {
            let fallback = NextendoUserInfo(pid: fallbackPid, username: fallbackUsername.isEmpty ? "Nextendo" : fallbackUsername, friendCode: fallbackFriendCode)
            completion(.success(fallback))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(NextendoSecrets.oauthClientId, forHTTPHeaderField: "X-Nextendo-Client-Id")
        request.timeoutInterval = 45.0
        
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self else { return }
            if let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let dict = (json["profile"] as? [String: Any]) ?? json
                let info = self.parseUserInfo(dict: dict, fallbackPid: fallbackPid, fallbackUsername: fallbackUsername, fallbackFriendCode: fallbackFriendCode)
                completion(.success(info))
            } else {
                let fallback = NextendoUserInfo(pid: fallbackPid, username: fallbackUsername.isEmpty ? "Nextendo" : fallbackUsername, friendCode: fallbackFriendCode)
                completion(.success(fallback))
            }
        }.resume()
    }
    
    public func parseUserInfo(
        dict: [String: Any],
        fallbackPid: UInt64 = 0,
        fallbackUsername: String = "",
        fallbackFriendCode: String = ""
    ) -> NextendoUserInfo {
        var username = fallbackUsername
        if let name = (dict["username"] as? String) ?? (dict["name"] as? String) ?? (dict["pseudo"] as? String), !name.isEmpty {
            username = name
        }
        
        var pid = fallbackPid
        if let pidNum = dict["pid"] as? UInt64 {
            pid = pidNum
        } else if let pidInt = dict["pid"] as? Int {
            pid = UInt64(pidInt)
        } else if let pidStr = dict["pid"] as? String, let parsed = UInt64(pidStr) {
            pid = parsed
        }
        
        var friendCode = fallbackFriendCode
        if let fc = (dict["friend_code"] as? String) ?? (dict["friendCode"] as? String), !fc.isEmpty {
            friendCode = fc
        }
        
        var avatarUrlStr: String? = nil
        if let aUrl = (dict["avatar_url"] as? String) ?? (dict["avatar"] as? String) ?? (dict["icon_url"] as? String), !aUrl.isEmpty {
            avatarUrlStr = aUrl
        }
        
        var miiData: String? = nil
        if let mii = dict["mii"] as? String, !mii.isEmpty {
            miiData = mii
        }
        
        return NextendoUserInfo(pid: pid, username: username, friendCode: friendCode, avatarUrl: avatarUrlStr, miiData: miiData)
    }
    
    // MARK: - Avatar Download & Normalization
    
    /// Downloads avatar picture from avatarUrlStr or canonical /api/avatar?pid={pid},
    /// normalizes it into standard JPEG format data suitable for Ryujinx and Profiles.json.
    public func fetchAvatar(
        pid: UInt64,
        avatarUrlStr: String?,
        baseUrl: String = NextendoProfileHelper.resolveBaseUrl(),
        completion: @escaping (Data?) -> Void
    ) {
        // Check cache first
        let cacheKey = "\(pid)_\(avatarUrlStr ?? "")" as NSString
        if let cachedImage = avatarCache.object(forKey: cacheKey),
           let jpegData = cachedImage.jpegData(compressionQuality: 0.9) {
            completion(jpegData)
            return
        }
        
        // Strategy 1: URL provided in profile/userinfo
        if let avatarUrlStr = avatarUrlStr, !avatarUrlStr.isEmpty {
            let fullUrl: URL?
            if avatarUrlStr.hasPrefix("http://") || avatarUrlStr.hasPrefix("https://") {
                fullUrl = URL(string: avatarUrlStr)
            } else if avatarUrlStr.hasPrefix("/") {
                fullUrl = URL(string: "\(baseUrl)\(avatarUrlStr)")
            } else {
                fullUrl = URL(string: "\(baseUrl)/\(avatarUrlStr)")
            }
            
            if let targetUrl = fullUrl {
                var request = URLRequest(url: targetUrl)
                request.setValue(NextendoSecrets.oauthClientId, forHTTPHeaderField: "X-Nextendo-Client-Id")
                request.timeoutInterval = 10.0
                
                URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 500
                    if statusCode >= 200 && statusCode < 300, let data = data, let image = UIImage(data: data) {
                        self?.avatarCache.setObject(image, forKey: cacheKey)
                        completion(image.jpegData(compressionQuality: 0.9))
                        return
                    }
                    
                    // Fallback to canonical /api/avatar?pid={pid}
                    self?.fetchCanonicalAvatar(pid: pid, baseUrl: baseUrl, cacheKey: cacheKey, completion: completion)
                }.resume()
                return
            }
        }
        
        // Strategy 2: Canonical /api/avatar?pid={pid}
        fetchCanonicalAvatar(pid: pid, baseUrl: baseUrl, cacheKey: cacheKey, completion: completion)
    }
    
    private func fetchCanonicalAvatar(
        pid: UInt64,
        baseUrl: String,
        cacheKey: NSString,
        completion: @escaping (Data?) -> Void
    ) {
        guard pid != 0, let url = URL(string: "\(baseUrl)/api/avatar?pid=\(pid)") else {
            completion(nil)
            return
        }
        
        var request = URLRequest(url: url)
        request.setValue(NextendoSecrets.oauthClientId, forHTTPHeaderField: "X-Nextendo-Client-Id")
        request.timeoutInterval = 10.0
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 500
            if statusCode >= 200 && statusCode < 300, let data = data, let image = UIImage(data: data) {
                self?.avatarCache.setObject(image, forKey: cacheKey)
                completion(image.jpegData(compressionQuality: 0.9))
            } else {
                completion(nil)
            }
        }.resume()
    }
    
    /// Generates a crisp default avatar with the player's initial letter and gradient background.
    public func generateDefaultAvatar(name: String) -> Data {
        let size = CGSize(width: 256, height: 256)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let bounds = CGRect(origin: .zero, size: size)
            
            // Soft gradient background
            let colors = [
                UIColor(red: 0.12, green: 0.45, blue: 0.95, alpha: 1.0).cgColor,
                UIColor(red: 0.05, green: 0.25, blue: 0.75, alpha: 1.0).cgColor
            ] as CFArray
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
                ctx.cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            } else {
                UIColor.systemBlue.setFill()
                ctx.fill(bounds)
            }
            
            let initial = String((name.isEmpty ? "N" : name).prefix(1)).uppercased()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 130, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            let textSize = initial.size(withAttributes: attributes)
            let textRect = CGRect(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            initial.draw(in: textRect, withAttributes: attributes)
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }
    
    // MARK: - Synchronizing with Profile Manager & Ryujinx
    
    /// Updates or creates the profile in system/Profiles.json, updates its avatar image,
    /// sets it as the active user, writes nextendo_account.txt, and reloads Ryujinx.
    public func applyNextendoProfile(
        name: String,
        imageData: Data?,
        pid: UInt64,
        nexToken: String,
        friendCode: String,
        miiData: String = "",
        completion: ((Bool, String) -> Void)? = nil
    ) {
        let finalImageData = imageData ?? generateDefaultAvatar(name: name)
        let finalImageB64 = finalImageData.base64EncodedString()
        let profilePath = NextendoProfileHelper.profilePath
        
        var profilesObj: Profiles? = nil
        if let data = try? Data(contentsOf: profilePath) {
            profilesObj = try? JSONDecoder().decode(Profiles.self, from: data)
        }
        
        var openedUserId = ""
        let nowTimestamp = Int(Date().timeIntervalSince1970)
        
        if var profiles = profilesObj {
            // Case 1: An existing profile has matching name (case-insensitive)
            if let existingIndex = profiles.profiles.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
                profiles.profiles[existingIndex].name = name
                profiles.profiles[existingIndex].image = finalImageB64
                profiles.profiles[existingIndex].last_modified_timestamp = nowTimestamp
                openedUserId = profiles.profiles[existingIndex].user_id
                
                if profiles.last_opened != openedUserId {
                    Ryujinx.closeUser(userId: profiles.last_opened)
                    Ryujinx.openUser(userId: openedUserId)
                    profiles.last_opened = openedUserId
                }
                
                if let encoded = try? JSONEncoder().encode(profiles) {
                    try? encoded.write(to: profilePath)
                }
                Ryujinx.refreshAccountManager()
            }
            // Case 2: Only the default single profile ("MeloNX" or default ID) exists
            else if profiles.profiles.count == 1 &&
                        (profiles.profiles[0].user_id == "00000000000000010000000000000000" || profiles.profiles[0].name == "MeloNX") {
                profiles.profiles[0].name = name
                profiles.profiles[0].image = finalImageB64
                profiles.profiles[0].last_modified_timestamp = nowTimestamp
                openedUserId = profiles.profiles[0].user_id
                profiles.last_opened = openedUserId
                
                Ryujinx.openUser(userId: openedUserId)
                
                if let encoded = try? JSONEncoder().encode(profiles) {
                    try? encoded.write(to: profilePath)
                }
                Ryujinx.refreshAccountManager()
            }
            // Case 3: Need to create a new profile with Ryujinx C# engine
            else {
                Ryujinx.createAccount(name: name, image: finalImageData)
                
                if let updatedData = try? Data(contentsOf: profilePath),
                   var newProfiles = try? JSONDecoder().decode(Profiles.self, from: updatedData),
                   let createdIndex = newProfiles.profiles.firstIndex(where: { $0.name == name }) {
                    
                    newProfiles.profiles[createdIndex].image = finalImageB64
                    newProfiles.profiles[createdIndex].last_modified_timestamp = nowTimestamp
                    openedUserId = newProfiles.profiles[createdIndex].user_id
                    
                    if newProfiles.last_opened != openedUserId {
                        Ryujinx.closeUser(userId: newProfiles.last_opened)
                        Ryujinx.openUser(userId: openedUserId)
                        newProfiles.last_opened = openedUserId
                    }
                    
                    if let encoded = try? JSONEncoder().encode(newProfiles) {
                        try? encoded.write(to: profilePath)
                    }
                    Ryujinx.refreshAccountManager()
                }
            }
        } else {
            // First time initialization
            Ryujinx.createAccount(name: name, image: finalImageData)
            if let updatedData = try? Data(contentsOf: profilePath),
               var newProfiles = try? JSONDecoder().decode(Profiles.self, from: updatedData),
               let created = newProfiles.profiles.first(where: { $0.name == name }) {
                openedUserId = created.user_id
                newProfiles.last_opened = openedUserId
                if let encoded = try? JSONEncoder().encode(newProfiles) {
                    try? encoded.write(to: profilePath)
                }
                Ryujinx.refreshAccountManager()
            }
        }
        
        if !openedUserId.isEmpty {
            UserDefaults.standard.set(openedUserId, forKey: "nextendoProfileUserId")
        }
        
        // Write nextendo_account.txt and reload
        writeNextendoAccountFile(
            pid: pid,
            username: name,
            friendCode: friendCode,
            nexToken: nexToken,
            profileUserId: openedUserId,
            miiData: miiData
        )
        
        Ryujinx.reloadNextendoAccount()
        initEnvironmentVariables(reloadAccount: true)
        
        NotificationCenter.default.post(name: Notification.Name("NextendoProfileUpdated"), object: nil)
        completion?(true, openedUserId)
    }
    
    public func writeNextendoAccountFile(
        pid: UInt64,
        username: String,
        friendCode: String,
        nexToken: String,
        profileUserId: String,
        miiData: String = ""
    ) {
        var cleanProfileUserId = profileUserId.replacingOccurrences(of: "-", with: "")
        if cleanProfileUserId.isEmpty {
            let profilePath = NextendoProfileHelper.profilePath
            if let data = try? Data(contentsOf: profilePath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let lastOpened = json["last_opened"] as? String {
                cleanProfileUserId = lastOpened.replacingOccurrences(of: "-", with: "")
            }
        }
        
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
        try? content.write(to: NextendoProfileHelper.accountFilePath, atomically: true, encoding: .utf8)
    }
    

    
    // MARK: - Full End-to-End Sync
    
    /// Fetches the profile info, downloads the avatar, persists credentials in Keychain/UserDefaults,
    /// applies the profile to Profiles.json and Ryujinx.
    public func fetchAndSyncProfile(
        authToken: String,
        nexToken: String,
        baseUrl: String = NextendoProfileHelper.resolveBaseUrl(),
        fallbackPid: UInt64 = 0,
        fallbackUsername: String = "",
        fallbackFriendCode: String = "",
        fallbackMii: String = "",
        completion: ((Bool, String?) -> Void)? = nil
    ) {
        fetchUserInfo(
            authToken: authToken,
            baseUrl: baseUrl,
            fallbackPid: fallbackPid,
            fallbackUsername: fallbackUsername,
            fallbackFriendCode: fallbackFriendCode
        ) { [weak self] result in
            guard let self = self else { return }
            
            let info: NextendoUserInfo
            switch result {
            case .success(let fetchedInfo):
                info = fetchedInfo
            case .failure:
                info = NextendoUserInfo(
                    pid: fallbackPid,
                    username: fallbackUsername.isEmpty ? "Nextendo" : fallbackUsername,
                    friendCode: fallbackFriendCode,
                    miiData: fallbackMii
                )
            }
            
            let finalName = info.username.isEmpty ? (fallbackUsername.isEmpty ? "Nextendo" : fallbackUsername) : info.username
            let finalPid = info.pid != 0 ? info.pid : fallbackPid
            let finalFc = info.friendCode.isEmpty ? fallbackFriendCode : info.friendCode
            let finalMii = (info.miiData?.isEmpty ?? true) ? fallbackMii : (info.miiData ?? "")
            
            // Persist credentials
            NextendoKeychainHelper.saveCredentials(
                token: authToken,
                nexToken: nexToken,
                pid: String(finalPid),
                username: finalName,
                friendCode: finalFc
            )
            
            UserDefaults.standard.set(authToken, forKey: "nextendoAuthToken")
            UserDefaults.standard.set(nexToken, forKey: "nextendoNexToken")
            UserDefaults.standard.set(String(finalPid), forKey: "nextendoPid")
            UserDefaults.standard.set(finalName, forKey: "nextendoUserPseudo")
            UserDefaults.standard.set(finalFc, forKey: "nextendoFriendCode")
            if !finalMii.isEmpty {
                UserDefaults.standard.set(finalMii, forKey: "nextendoMiiData")
                if let miiBytes = Data(base64Encoded: finalMii) {
                    Ryujinx.injectNextendoMii(data: miiBytes)
                }
            }
            
            // Download avatar
            self.fetchAvatar(pid: finalPid, avatarUrlStr: info.avatarUrl, baseUrl: baseUrl) { avatarData in
                DispatchQueue.main.async {
                    self.applyNextendoProfile(
                        name: finalName,
                        imageData: avatarData,
                        pid: finalPid,
                        nexToken: nexToken,
                        friendCode: finalFc,
                        miiData: finalMii
                    ) { success, userId in
                        completion?(success, userId)
                    }
                }
            }
        }
    }
    
    /// Syncs currently saved Nextendo account if present.
    public func syncCurrentSavedAccount(completion: ((Bool, String?) -> Void)? = nil) {
        guard let creds = NextendoKeychainHelper.loadCredentials(), !creds.token.isEmpty else {
            completion?(false, "No Nextendo account credentials found.")
            return
        }
        
        let pidNum = UInt64(creds.pid) ?? 0
        fetchAndSyncProfile(
            authToken: creds.token,
            nexToken: creds.nexToken,
            fallbackPid: pidNum,
            fallbackUsername: creds.username,
            fallbackFriendCode: creds.friendCode,
            completion: completion
        )
    }
    
    /// Automatically removes the Nextendo profile on sign out, switching to another profile
    /// or creating a default clean "MeloNX" profile if no other profiles exist.
    public func removeNextendoProfileOnSignOut() {
        let profilePath = NextendoProfileHelper.profilePath
        let boundProfileId = UserDefaults.standard.string(forKey: "nextendoProfileUserId") ?? ""
        let savedPseudo = UserDefaults.standard.string(forKey: "nextendoUserPseudo") ?? ""
        
        if let data = try? Data(contentsOf: profilePath),
           var profiles = try? JSONDecoder().decode(Profiles.self, from: data) {
            
            let targetIndex = profiles.profiles.firstIndex(where: {
                (!boundProfileId.isEmpty && $0.user_id == boundProfileId) ||
                (!savedPseudo.isEmpty && $0.name.lowercased() == savedPseudo.lowercased())
            })
            
            if let index = targetIndex {
                let removedUser = profiles.profiles.remove(at: index)
                
                // If the removed profile was currently open, switch or create fallback
                if profiles.last_opened == removedUser.user_id {
                    Ryujinx.closeUser(userId: removedUser.user_id)
                    
                    if let fallback = profiles.profiles.first {
                        profiles.last_opened = fallback.user_id
                        Ryujinx.openUser(userId: fallback.user_id)
                    } else {
                        // Recreate default local profile so emulator always has an account
                        let defaultAvatarData = self.generateDefaultAvatar(name: "MeloNX")
                        Ryujinx.createAccount(name: "MeloNX", image: defaultAvatarData)
                        if let reloadedData = try? Data(contentsOf: profilePath),
                           let reloaded = try? JSONDecoder().decode(Profiles.self, from: reloadedData) {
                            profiles = reloaded
                            if let first = profiles.profiles.first {
                                profiles.last_opened = first.user_id
                                Ryujinx.openUser(userId: first.user_id)
                            }
                        }
                    }
                }
                
                if let encoded = try? JSONEncoder().encode(profiles) {
                    try? encoded.write(to: profilePath)
                }
                Ryujinx.refreshAccountManager()
            }
        }
        
        UserDefaults.standard.removeObject(forKey: "nextendoProfileUserId")
        NotificationCenter.default.post(name: Notification.Name("NextendoProfileUpdated"), object: nil)
    }
    
    // MARK: - NEX Token Retrieval (Nextendo Developers Section 10)
    
    /// Obtains the signed NEX login token (prefixed with nx2.) from Nextendo using an OAuth Bearer access token.
    /// URL: GET /api/nex-token
    /// Headers: Authorization: Bearer <oauth_access_token>
    public func fetchNexToken(
        accessToken: String,
        baseUrl: String = NextendoProfileHelper.resolveBaseUrl(),
        completion: @escaping (Result<NexTokenResult, Error>) -> Void
    ) {
        let cleanToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty else {
            completion(.failure(NSError(domain: "NextendoAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Access token is empty."])))
            return
        }
        
        guard let url = URL(string: "\(baseUrl)/api/nex-token") else {
            completion(.failure(URLError(.badURL)))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(NextendoSecrets.oauthClientId, forHTTPHeaderField: "X-Nextendo-Client-Id")
        request.timeoutInterval = 30.0
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(URLError(.badServerResponse)))
                return
            }
            
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(NSError(domain: "NextendoAuth", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON response from /api/nex-token (HTTP \(httpResponse.statusCode))."])))
                return
            }
            
            if httpResponse.statusCode != 200 {
                let err = (json["error"] as? String) ?? (json["message"] as? String) ?? "Failed to obtain NEX token (HTTP \(httpResponse.statusCode))."
                completion(.failure(NSError(domain: "NextendoAuth", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: err])))
                return
            }
            
            guard let nexToken = json["nex_token"] as? String, !nexToken.isEmpty else {
                completion(.failure(NSError(domain: "NextendoAuth", code: -2, userInfo: [NSLocalizedDescriptionKey: "No nex_token returned from /api/nex-token."])))
                return
            }
            
            var pid: UInt64 = 0
            if let pNum = json["pid"] as? UInt64 {
                pid = pNum
            } else if let pInt = json["pid"] as? Int {
                pid = UInt64(pInt)
            } else if let pStr = json["pid"] as? String, let p = UInt64(pStr) {
                pid = p
            }
            
            let username = (json["username"] as? String) ?? ""
            let friendCode = (json["friend_code"] as? String) ?? ""
            
            completion(.success(NexTokenResult(
                nexToken: nexToken,
                pid: pid,
                username: username,
                friendCode: friendCode
            )))
        }.resume()
    }
    
    // MARK: - Selected Profile Enforcement
    
    public var isConnected: Bool {
        let creds = NextendoKeychainHelper.loadCredentials()
        let hasNexToken = !(creds?.nexToken.isEmpty ?? true) || !(UserDefaults.standard.string(forKey: "nextendoNexToken")?.isEmpty ?? true)
        let hasToken = !(creds?.token.isEmpty ?? true) || !(UserDefaults.standard.string(forKey: "nextendoAuthToken")?.isEmpty ?? true)
        let pid = creds?.pid ?? UserDefaults.standard.string(forKey: "nextendoPid") ?? ""
        return (hasNexToken || hasToken) && (!pid.isEmpty && pid != "0")
    }
    
    /// Guarantees that the active (selected) profile in Profiles.json and Ryujinx is the Nextendo profile
    /// if the user is authenticated, even across app restarts.
    @discardableResult
    public func ensureNextendoProfileSelected() -> Bool {
        guard isConnected else { return false }
        
        let profilePath = NextendoProfileHelper.profilePath
        guard let data = try? Data(contentsOf: profilePath),
              var profiles = try? JSONDecoder().decode(Profiles.self, from: data) else {
            return false
        }
        
        let boundProfileId = UserDefaults.standard.string(forKey: "nextendoProfileUserId") ?? ""
        let savedPseudo = UserDefaults.standard.string(forKey: "nextendoUserPseudo") ?? ""
        
        let targetIndex = profiles.profiles.firstIndex(where: {
            (!boundProfileId.isEmpty && $0.user_id == boundProfileId) ||
            (!savedPseudo.isEmpty && $0.name.lowercased() == savedPseudo.lowercased())
        })
        
        // If the profile does not exist in Profiles.json, re-create and apply it
        if targetIndex == nil {
            if let creds = NextendoKeychainHelper.loadCredentials(), !creds.nexToken.isEmpty {
                let pidNum = UInt64(creds.pid) ?? 0
                let mii = UserDefaults.standard.string(forKey: "nextendoMiiData") ?? ""
                self.applyNextendoProfile(
                    name: creds.username.isEmpty ? "Nextendo" : creds.username,
                    imageData: nil,
                    pid: pidNum,
                    nexToken: creds.nexToken,
                    friendCode: creds.friendCode,
                    miiData: mii
                )
                return true
            }
            return false
        }
        
        guard let index = targetIndex else { return false }
        let targetProfile = profiles.profiles[index]
        
        if boundProfileId != targetProfile.user_id {
            UserDefaults.standard.set(targetProfile.user_id, forKey: "nextendoProfileUserId")
        }
        
        if profiles.last_opened == targetProfile.user_id {
            return false
        }
        
        if !profiles.last_opened.isEmpty {
            Ryujinx.closeUser(userId: profiles.last_opened)
        }
        Ryujinx.openUser(userId: targetProfile.user_id)
        profiles.last_opened = targetProfile.user_id
        
        if let encoded = try? JSONEncoder().encode(profiles) {
            try? encoded.write(to: profilePath)
        }
        
        Ryujinx.refreshAccountManager()
        Ryujinx.reloadNextendoAccount()
        initEnvironmentVariables(reloadAccount: true)
        NotificationCenter.default.post(name: Notification.Name("NextendoProfileUpdated"), object: nil)
        
        return true
    }
}



