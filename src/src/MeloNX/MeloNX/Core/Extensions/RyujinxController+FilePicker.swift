//
//  RyujinxController+FilePicker.swift
//  MeloNX
//
//  Created by Stossy11 on 30/4/2026.
//

import Foundation
import UIKit
import Combine

extension RyujinxController {
    public func handleRunningGame(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                return
            }
            
            _ = url.startAccessingSecurityScopedResource()
            
            do {
                let handle = try FileHandle(forReadingFrom: url)
                let fileExtension = (url.pathExtension as NSString)
                
                let gameInfo = Ryujinx.getGameInfo(arg0: handle.fileDescriptor, arg1: fileExtension, path: url)
                
                self.startGame(gameInfo)
            } catch {
            }
            
        case .failure(let err):
            print("File import failed: \(err.localizedDescription)")
        }
    }
    
    
    public func handleAddingGame(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                return
            }
            
            let cool = url.startAccessingSecurityScopedResource()
            defer { cool ? url.stopAccessingSecurityScopedResource() : () }
            
            do {
                if !GameFileType.isSupported(fileExtension: url.pathExtension) {
                    AppAlerts.showSyncAlert(title: "Failed to import", message: "Unsupported file extension")
                    return
                }
                
                let fileManager = FileManager.default
                let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
                let romsDirectory = documentsDirectory.appendingPathComponent("roms")
                
                if !fileManager.fileExists(atPath: romsDirectory.path) {
                    try? fileManager.createDirectory(at: romsDirectory, withIntermediateDirectories: true, attributes: nil)
                }
                
                let destinationURL = romsDirectory.appendingPathComponent(url.lastPathComponent)
                try fileManager.copyItem(at: url, to: destinationURL)
                
                self.loadGames()
            } catch {
                AppAlerts.showSyncAlert(title: "Failed to import", message: error.localizedDescription)
            }
        case .failure(let err):
            AppAlerts.showSyncAlert(title: "Failed to import", message: err.localizedDescription)
        }
    }
    
    public func handleFirmwareImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                return
            }
            
            let isScoped = url.startAccessingSecurityScopedResource()
            defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
            
            do {
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("firmware_import")
                try? FileManager.default.removeItem(at: tempDir)
                try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let localURL = tempDir.appendingPathComponent(url.lastPathComponent)
                
                if FileManager.default.fileExists(atPath: localURL.path) {
                    try? FileManager.default.removeItem(at: localURL)
                }
                try FileManager.default.copyItem(at: url, to: localURL)
                defer { try? FileManager.default.removeItem(at: localURL) }
                
                try Ryujinx.installFirmware(at: localURL.path)
                objectWillChange.send()
                _ = firmwareVersion
            } catch FirmwareInstallationError.failedInstall(let string) {
                AppAlerts.showSyncAlert(title: "Installing Firmware Failed", message: string, hasCancel: false)
            } catch {
                AppAlerts.showSyncAlert(title: "Installing Firmware Failed", message: error.localizedDescription, hasCancel: false)
            }
        case .failure(let error):
            AppAlerts.showSyncAlert(title: "Installing Firmware Failed", message: error.localizedDescription, hasCancel: false)
        }
    }
    
}
