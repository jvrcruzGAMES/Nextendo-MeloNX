//
//  NextendoKeychainHelper.swift
//  MeloNX
//
//  Secure Keychain storage for Nextendo Network authentication credentials.
//

import Foundation
import Security

public enum NextendoKeychainHelper {
    private static let service = "network.nextendo.melonx"
    
    public enum Key: String, CaseIterable {
        case authToken = "authToken"
        case nexToken = "nexToken"
        case pid = "pid"
        case username = "username"
        case friendCode = "friendCode"
        
        var userDefaultsKey: String {
            switch self {
            case .authToken: return "nextendoAuthToken"
            case .nexToken: return "nextendoNexToken"
            case .pid: return "nextendoPid"
            case .username: return "nextendoUserPseudo"
            case .friendCode: return "nextendoFriendCode"
            }
        }
    }
    
    public struct Credentials {
        public let token: String // Primary token for online / auth
        public let authToken: String
        public let nexToken: String
        public let pid: String
        public let username: String
        public let friendCode: String
        
        public var isValid: Bool {
            return (!token.isEmpty || !authToken.isEmpty || !nexToken.isEmpty) && !pid.isEmpty && pid != "0"
        }
    }
    
    // MARK: - Low-level Keychain primitives with UserDefaults fallback
    
    @discardableResult
    public static func saveItem(key: Key, value: String) -> Bool {
        // 1. Mirror directly to UserDefaults so credentials survive any Keychain sandboxing issues
        UserDefaults.standard.set(value, forKey: key.userDefaultsKey)
        
        // 2. Persist to Keychain
        guard let data = value.data(using: .utf8) else { return true }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        
        SecItemDelete(query as CFDictionary)
        
        var newAttributes = query
        newAttributes[kSecValueData as String] = data
        newAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        
        let status = SecItemAdd(newAttributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            _ = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        }
        
        return true
    }
    
    public static func loadItem(key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        
        if status == errSecSuccess, let data = dataTypeRef as? Data, let str = String(data: data, encoding: .utf8), !str.isEmpty {
            UserDefaults.standard.set(str, forKey: key.userDefaultsKey)
            return str
        }
        
        // Fallback to UserDefaults
        if let fallback = UserDefaults.standard.string(forKey: key.userDefaultsKey), !fallback.isEmpty {
            return fallback
        }
        
        return nil
    }
    
    @discardableResult
    public static func deleteItem(key: Key) -> Bool {
        UserDefaults.standard.removeObject(forKey: key.userDefaultsKey)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
    
    // MARK: - Token helpers
    
    @discardableResult
    public static func saveToken(_ token: String) -> Bool {
        return saveItem(key: .authToken, value: token)
    }
    
    public static func loadToken() -> String? {
        return loadItem(key: .authToken)
    }
    
    @discardableResult
    public static func deleteToken() -> Bool {
        return deleteItem(key: .authToken)
    }
    
    @discardableResult
    public static func saveNexToken(_ token: String) -> Bool {
        return saveItem(key: .nexToken, value: token)
    }
    
    public static func loadNexToken() -> String? {
        return loadItem(key: .nexToken)
    }
    
    // MARK: - PID helpers
    
    @discardableResult
    public static func savePid(_ pid: String) -> Bool {
        return saveItem(key: .pid, value: pid)
    }
    
    public static func loadPid() -> String? {
        return loadItem(key: .pid)
    }
    
    // MARK: - Username helpers
    
    @discardableResult
    public static func saveUsername(_ username: String) -> Bool {
        return saveItem(key: .username, value: username)
    }
    
    public static func loadUsername() -> String? {
        return loadItem(key: .username)
    }
    
    // MARK: - Friend Code helpers
    
    @discardableResult
    public static func saveFriendCode(_ friendCode: String) -> Bool {
        return saveItem(key: .friendCode, value: friendCode)
    }
    
    public static func loadFriendCode() -> String? {
        return loadItem(key: .friendCode)
    }
    
    // MARK: - High-level Aggregate helpers
    
    @discardableResult
    public static func saveCredentials(token: String, nexToken: String? = nil, pid: String, username: String, friendCode: String) -> Bool {
        _ = saveItem(key: .authToken, value: token)
        if let nex = nexToken, !nex.isEmpty {
            _ = saveItem(key: .nexToken, value: nex)
        }
        _ = saveItem(key: .pid, value: pid)
        _ = saveItem(key: .username, value: username)
        _ = saveItem(key: .friendCode, value: friendCode)
        return true
    }
    
    public static func loadCredentials() -> Credentials? {
        let auth = loadItem(key: .authToken) ?? ""
        let nex = loadItem(key: .nexToken) ?? ""
        let pid = loadItem(key: .pid) ?? ""
        let username = loadItem(key: .username) ?? ""
        let friendCode = loadItem(key: .friendCode) ?? ""
        
        if auth.isEmpty && nex.isEmpty && (pid.isEmpty || pid == "0") {
            return nil
        }
        
        return Credentials(token: auth, authToken: auth, nexToken: nex, pid: pid.isEmpty ? "0" : pid, username: username, friendCode: friendCode)
    }
    
    @discardableResult
    public static func clearAllCredentials() -> Bool {
        var success = true
        for key in Key.allCases {
            if !deleteItem(key: key) {
                success = false
            }
        }
        return success
    }
}
