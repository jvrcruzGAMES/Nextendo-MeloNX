//
//  RyujinxController.swift
//  MeloNX
//
//  Created by Stossy11 on 20/4/2026.
//

import SwiftUI
import Combine

extension URL {
    @available(iOS, introduced: 14.0, deprecated: 16.0, message: "Use URL.documentsDirectory on iOS 16 and above")
    static var documentsDirectory: URL {
        let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentDirectory
    }
    
    static var configFolderURL: URL {
        documentsDirectory.appendingPathComponent("config")
    }
    
    static func perGameConfigURL(_ titleId: String) -> URL {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: configFolderURL.path) {
            try? fileManager.createDirectory(at: configFolderURL, withIntermediateDirectories: true)
        }
        
        return configFolderURL.appendingPathComponent(titleId + "_config.json")
    }
    
    static var configURL: URL {
        documentsDirectory.appendingPathComponent("config.json")
    }
    
    static var romsURL: URL {
        documentsDirectory.appendingPathComponent("roms")
    }
    
    static var keyboardConfigURL: URL {
        documentsDirectory.appendingPathComponent("keyboardConfig.json")
    }
    
    static var keysFolderURL: URL {
        documentsDirectory.appendingPathComponent("system")
    }
    
    static var modsFolderURL: URL {
        documentsDirectory.appendingPathComponent("mods")
    }
    
    static func modFolderURL(for game: GameInfo) -> URL {
        modsFolderURL.appendingPathComponent("contents").appendingPathComponent(game.titleId)
    }
    
    static var logsFolderURL: URL {
        documentsDirectory.appendingPathComponent("logs")
    }
    
    static func cacheFolderURL(for game: GameInfo) -> URL {
        let fileManager = FileManager.default
        let gamesFolder = documentsDirectory.appendingPathComponent("games")
        
        return gamesFolder.appendingPathComponent(game.titleId).appendingPathComponent("cache")
    }
}

extension UIDevice {
    var supportsBCTextureCompression: Bool {
        if #available(iOS 16.4, *), let device = MTLCreateSystemDefaultDevice() {
           return device.supportsBCTextureCompression
        }
        
        return false
    }
}

enum StartedState {
    case none
    case entitlement
    case extendedEntitlement
    case noJIT
    case usersList
}

enum RunningState {
    case started(game: GameInfo, state: StartedState = .none)
    case stopped
    case crashed(result: String)
    
    func hasStarted() -> Bool {
        if case .started(_, let state) = self {
            return state != .noJIT
        }
        return false
    }
    
    func isRunning() -> Bool {
        if case .started(_, let state) = self {
            return state == .none
        }
        return false
    }
    
    func isEntitlement() -> Bool {
        if case .started(_, let state) = self {
            return state == .entitlement
        }
        return false
    }
    
    func hasCrashed() -> Bool {
        if case .crashed = self {
            return true
        }
        return false
    }
}



class RyujinxController: ObservableObject {
    static var shared: RyujinxController = .init()
    
    private init() {
        loadConfig()
    }
    
    @Published var isRunning: RunningState = .stopped
    @Published var games: [GameInfo] = []
    @Published var settings: Options = .init(inputPath: "")
    
    @Published var perSettings: [String: Options] = [:]
    
    var currentSettings: Options {
        get {
            if case .started(let game, _) = isRunning {
                return perSettings[game.titleId] ?? settings
            }
            
            return settings
        } set {
            self.objectWillChange.send()
            if case .started(let game, _) = isRunning, perSettings[game.titleId]  != nil {
                perSettings[game.titleId] = newValue
            }
            
            settings = newValue
        }
    }
    
    var lastGameLaunched: String? {
        get {
            UserDefaults.standard.string(forKey: "lastGameLaunched")
        } set {
            if let cool = newValue { UserDefaults.standard.set(cool, forKey: "lastGameLaunched"); return }
            UserDefaults.standard.removeObject(forKey: "lastGameLaunched")
        }
    }
    
    @Published var _isPaused: Bool = false
    
    @Published var wasManuallyPaused: Bool = false
    
    var isPaused: Bool {
        get {
            return _isPaused
        } set {
            _isPaused = newValue
            Ryujinx.togglePauseEmulation(_isPaused)
        }
    }
    
    private static var hasScript: Bool = false
    private var controllerManager: ControllerManager = .shared
    private var emulationThreadActive = false
    
    var firmwareVersion: String {
        return Ryujinx.installedFirmwareVersion
    }
    
    var firmwareInstalled: Bool {
        let v = Ryujinx.installedFirmwareVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        return !v.isEmpty && v != "Not Installed" && v != "Cannot find registered" && v != "0.0.0"
    }
    
    var isJITEnabled: Bool {
        jitEnabled()
    }
    
    var hasIncreasedMemoryLimitEntitlement: Bool {
        checkAppEntitlement("com.apple.developer.kernel.increased-memory-limit")
    }
    
    var hasExtendedVirtualAddressingEntitlement: Bool {
        checkAppEntitlement("com.apple.developer.kernel.extended-virtual-addressing")
    }
    
    
    
    func startGame(_ game: GameInfo) {
        guard !emulationThreadActive, !isRunning.hasStarted() else { return }
        
        initEnvironmentVariables()
        loadConfig()
        
        if !hasIncreasedMemoryLimitEntitlement {
            isRunning = .started(game: game, state: .entitlement)
            lastGameLaunched = nil
            return
        }
        
        if !hasExtendedVirtualAddressingEntitlement && AppEnvironment.shared.requiresExtendedVirtualAddressing() {
            isRunning = .started(game: game, state: .extendedEntitlement)
            lastGameLaunched = nil
            return
        }
        
        // extendedEntitlement
        
        if !isJITEnabled {
            isRunning = .started(game: game, state: .noJIT)
            return
        }
        
        lastGameLaunched = nil
        
        let config = pullKeyboardConfig()
        Ryujinx.setKeyboardConfig(config)
        
        controllerManager.attachAllControllers()
        
        if NativeSettingsManager.exists(game.titleId) {
            NativeSettingsManager.setShared(game.titleId, pullOriginal: true)
        }
        
        loadWithoutSave(game.titleId)
        
        var settings = perSettings[game.titleId] ?? settings

        let preferredNetworkInterfaceId = settings.multiplayerLanInterfaceId == "0"
            ? self.settings.multiplayerLanInterfaceId
            : settings.multiplayerLanInterfaceId
        
        settings.resolveMultiplayerLanInterface(preferredInterfaceId: preferredNetworkInterfaceId)
        
        settings.inputPath = game.fileURL.path
        settings.backendThreading = .on
        settings.enableInternetAccess = true
        
        isRunning = .started(game: game)
        _isPaused = false
        wasManuallyPaused = false
        emulationThreadActive = true
        
        let nativeSettingsManager = NativeSettingsManager.shared
        
        if !(nativeSettingsManager.writeStdout.value as Bool) {
            redirectStdIOToFile()
        }
        
        Thread.detachNewThread {
            let response = Ryujinx.mainRyu(settings)
            
            DispatchQueue.main.async {
                self.emulationThreadActive = false
                
                if response != 0 {
                    self.isRunning = .crashed(result: "Code: \(response)")
                } else {
                    self.isRunning = .stopped
                }
            }
        }
    }
    
    
    func redirectStdIOToFile() {
        let fileManager = FileManager.default
        
        let logsDir = URL.logsFolderURL
        
        if !fileManager.fileExists(atPath: logsDir.path) {
            try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        }
        
        cleanupOldLogs(in: logsDir, keep: 5)
        
        let fileName = "MeloNX-Log-\(Date()).log"
        let logURL = logsDir.appendingPathComponent(fileName)
        
        fileManager.createFile(atPath: logURL.path, contents: nil)
        
        let fd = open(logURL.path, O_WRONLY | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        
        dup2(fd, STDOUT_FILENO)
        dup2(fd, STDERR_FILENO)
        
        close(fd)
    }
    
    func cleanupOldLogs(in directory: URL, keep: Int) {
        let fileManager = FileManager.default
        
        guard var files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return }
        
        files = files.compactMap({ $0.lastPathComponent.hasPrefix("MeloNX-Log-") ? $0 : nil })
        
        let sortedFiles = files.sorted {
            let date1 = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let date2 = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return date1 > date2
        }
        
        let filesToDelete = sortedFiles.dropFirst(keep)
        
        for file in filesToDelete {
            try? fileManager.removeItem(at: file)
        }
    }
    
    func loadConfig() {
        if var settings = try? Options.loadFromJSON(at: .configURL) {
            settings.resolveMultiplayerLanInterface()
            self.settings = settings
            try? self.settings.saveAsJSON(to: .configURL)
        } else {
            self.settings.resolveMultiplayerLanInterface()
            try? FileManager.default.removeItem(at: .configURL)
            try? self.settings.saveAsJSON(to: .configURL)
        }
    }
    
    func saveConfig() {
        do {
            try settings.saveAsJSON(to: .configURL)
        } catch {
            try? FileManager.default.removeItem(at: .configURL)
            try? settings.saveAsJSON(to: .configURL)
        }
    }
    
    func loadPerGameConfig(_ titleId: String) {
        let setting2s = perSettings[titleId] ??  .init(inputPath: "")
        if let settings = try? Options.loadFromJSON(at: .perGameConfigURL(titleId)) {
            self.perSettings[titleId] = settings
        } else {
            try? FileManager.default.removeItem(at: .perGameConfigURL(titleId))
            try? setting2s.saveAsJSON(to: .perGameConfigURL(titleId))
            self.perSettings[titleId] = .init(inputPath: "")
        }
    }
    
    func loadWithoutSave(_ titleId: String) {
        if let settings = try? Options.loadFromJSON(at: .perGameConfigURL(titleId)) {
            self.perSettings[titleId] = settings
        }
    }
    
    func savePerGameConfig(_ titleId: String) {
        let setting2s = perSettings[titleId] ??  .init(inputPath: "")
        try? setting2s.saveAsJSON(to: .perGameConfigURL(titleId))
    }
    
    
    func loadGamesArray() -> [GameInfo] {
        let fileManager = FileManager.default
        var romDirectories: [URL] = [.romsURL]
        
        let romFolderManager = ROMFolderManager.shared
        romFolderManager.loadBookmarks()
        
        for bookmarkData in romFolderManager.bookmarks {
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                
                if isStale, fileManager.fileExists(atPath: url.path) {
                    _ = romFolderManager.addFolder(url: url)
                }
                
                if url.startAccessingSecurityScopedResource() {
                    romDirectories.append(url)
                }
            } catch {
                print("Failed to resolve bookmark: \(error)")
            }
        }
        
        var games: [GameInfo] = []
        for romsDirectory in romDirectories {
            guard let enumerator = fileManager.enumerator(at: romsDirectory, includingPropertiesForKeys: nil) else {
                continue
            }
            
            for case let fileURL as URL in enumerator {
                guard GameFileType.isSupported(fileExtension: fileURL.pathExtension) else { continue }
                
                do {
                    let handle = try FileHandle(forReadingFrom: fileURL)
                    let fileExtension = fileURL.pathExtension as NSString
                    games.append(Ryujinx.getGameInfo(arg0: handle.fileDescriptor, arg1: fileExtension, path: fileURL))
                } catch {
                    print("Failed to read file at \(fileURL): \(error)")
                }
            }
        }
        
        return games
    }
    
    
    func loadGames() {
        let fileManager = FileManager.default
        guard let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        
        var romDirectories: [URL] = [documentsDirectory.appendingPathComponent("roms")]
        
        let romFolderManager = ROMFolderManager.shared
        romFolderManager.loadBookmarks()
        
        for bookmarkData in romFolderManager.bookmarks {
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                
                if isStale, fileManager.fileExists(atPath: url.path) {
                    _ = romFolderManager.addFolder(url: url)
                }
                
                if url.startAccessingSecurityScopedResource() {
                    romDirectories.append(url)
                }
            } catch {
                print("Failed to resolve bookmark: \(error)")
            }
        }
        
        let defaultRomsDirectory = documentsDirectory.appendingPathComponent("roms")
        if !fileManager.fileExists(atPath: defaultRomsDirectory.path) {
            do {
                try fileManager.createDirectory(at: defaultRomsDirectory, withIntermediateDirectories: true)
            } catch {
                print("Failed to create roms directory: \(error)")
            }
        }
        
        var games: [GameInfo] = []
        for romsDirectory in romDirectories {
            guard let enumerator = fileManager.enumerator(at: romsDirectory, includingPropertiesForKeys: nil) else {
                continue
            }
            
            for case let fileURL as URL in enumerator {
                guard GameFileType.isSupported(fileExtension: fileURL.pathExtension) else { continue }
                
                do {
                    let handle = try FileHandle(forReadingFrom: fileURL)
                    let fileExtension = fileURL.pathExtension as NSString
                    games.append(Ryujinx.getGameInfo(arg0: handle.fileDescriptor, arg1: fileExtension, path: fileURL))
                } catch {
                    print("Failed to read file at \(fileURL): \(error)")
                }
            }
        }
        
        self.games = games
        
        sortGames(true)
    }
    
    func sortGames(_ isCalled: Bool = false) {
        let nativeSettingsManager: NativeSettingsManager = .shared
        switch nativeSettingsManager.gameSort(GameSort.none).value {
        case .alphabetical:
            games = games.sorted { $0.titleName < $1.titleName }
        case .newest:
            games = games.sorted { (game, gam2) -> Bool in
                let date1 = (try? game.fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let date2 = (try? gam2.fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                
                return (date1 ?? Date.distantPast) > (date2 ?? Date.distantPast)
            }
        case .none:
            if !isCalled { loadGames() }
        }
    }
    
    
    func clearShaderCacheWithConfirmation(_ game: GameInfo? = nil) {
        AppAlerts.showAlert(title: "Shader Cache Deletion.", message: "Are you sure you want to delete \(game?.titleName ?+ "'s", default: "all") shader cache?", actions: [
            (title: "Cancel", style: .cancel, handler: nil),
            (title: "Delete", style: .destructive, handler: {
                self.clearShaderCache(game, withConfirmation: true)
            })
        ])
    }
    
    func clearShaderCache(_ game: GameInfo? = nil, withConfirmation: Bool = false) {
        let fileManager = FileManager.default
        
        guard let game else {
            let games = loadGamesArray()
            
            for game in games {
                print("Clear Shader Cache: \(URL.cacheFolderURL(for: game).path), exists: \(fileManager.fileExists(atPath: URL.cacheFolderURL(for: game).path))")
                try? fileManager.removeItem(at: .cacheFolderURL(for: game))
            }
            
            if withConfirmation {
                AppAlerts.showAlert(title: "Shader Cache Deleted.", message: "All cached shaders have been deleted.", actions: [
                    (title: "OK", style: .default, handler: nil)
                ])
            }
            
            return
        }
        
        do {
            if fileManager.fileExists(atPath: URL.cacheFolderURL(for: game).path) {
                try fileManager.removeItem(at: .cacheFolderURL(for: game))
            }
            
            if withConfirmation {
                AppAlerts.showAlert(title: "Shader Cache Deleted.", message: "Shader Cache for \(game.titleName) have been deleted.", actions: [
                    (title: "OK", style: .default, handler: nil)
                ])
            }
        } catch {
            if withConfirmation {
                AppAlerts.showAlert(title: "Failed to Delete Shader Cache.", message: "Failed to delete cached shaders for \(game.titleName).", actions: [
                    (title: "OK", style: .default, handler: nil)
                ])
            }
        }
    }
    
    static func attemptToMapDualMapping() -> Bool {
        if hasScript { return true }
        
        hasScript = Ryujinx.initDualMapping()
        
        return hasScript
    }
    
    func attemptToMapDualMapping() -> Bool {
        return Self.attemptToMapDualMapping()
    }
}
