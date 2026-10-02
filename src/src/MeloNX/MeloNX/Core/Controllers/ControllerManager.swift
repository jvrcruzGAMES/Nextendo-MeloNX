//
//  ControllerManager.swift
//  MeloNX
//
//  Created by Stossy11 on 19/10/2025.
//

import Foundation
import Combine
import GameController
import SwiftUI

class ControllerManager: ObservableObject {
    static var shared = ControllerManager()
    let virtualController = BaseController(nativeController: nil)
    @AppStorage("isVirtualController") var isVCA: Bool = true
    
    private let controllerQueue = DispatchQueue(label: "com.stossy11.melonx.controllermanager", attributes: .concurrent)
    
    private var _privAllControllers: [BaseController] = []
    @Published var allControllers: [BaseController] = []
    
    @Published var selectedControllers: [String] = [] 
    private var didInitControllerObservers = false
    
    
    func initAll() {
        refreshControllersList()
        initControllerObservers()
    }
    
    private init() {
        controllerQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self._privAllControllers.append(self.virtualController)
            let controllers = self._privAllControllers
            
            DispatchQueue.main.async {
                self.allControllers = controllers
            }
        }
    }
    
    
    func refreshControllersList(_ inGameSelector: Bool = false) {
        let connectedNativeControllers = Set(GCController.controllers())
        
        controllerQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            var controllersToRemove: [BaseController] = []
            for controller in self._privAllControllers where !controller.virtual {
                if let native = controller.nativeController, !connectedNativeControllers.contains(native) {
                    controllersToRemove.append(controller)
                }
            }
            
            for controller in controllersToRemove {
                controller.cleanup()
                self._privAllControllers.removeAll { $0 === controller }
            }
            
            for (_, nativeController) in connectedNativeControllers.enumerated() {
                if !self._privAllControllers.contains(where: { $0.nativeController === nativeController }) {
                    let newController = NativeController(nativeController: nativeController)
                    self._privAllControllers.append(newController)
                }
            }
            
            // Full Keyboard Support may come eventually, i'm just too lazy :3
            // _privAllControllers.append(KBController()) // This was just an experiment, yes it did work, no i'm not bothered to fully implement it.
            
            let physicalControllers = self._privAllControllers.prefix(7).filter { !$0.virtual }.compactMap(\.id) as [String]
            let controllers = Array(self._privAllControllers.prefix(7))
            
            let selectedControllerIds: [String]
            
            if inGameSelector {
                selectedControllerIds = selectedControllers
            } else {
                selectedControllerIds = physicalControllers.isEmpty ? [self.virtualController.id] : physicalControllers
            }
            // RyujinxController.shared.isRunning.isRunning(
            
            DispatchQueue.main.async {
                self.allControllers = controllers
                self.selectedControllers = selectedControllerIds
                
                let isRunning = RyujinxController.shared.isRunning.isRunning()
                
                if isRunning {
                    self.attachAllControllers(selectedControllerIds: selectedControllerIds)
                }
            }
        }
    }
    
    func attachAllControllers() {
        attachAllControllers(selectedControllerIds: selectedControllerIdsSnapshot())
    }
    
    private func attachAllControllers(selectedControllerIds: [String]) {
        let config = RyujinxController.shared.settings
        
        controllerQueue.sync {
            for controller in _privAllControllers {
                Ryujinx.detachGamepad(controller.pointer)
            }
            
            for (index, controllerId) in selectedControllerIds.enumerated() {
                let cont = _privAllControllers.first(where: { $0.id == controllerId })
                guard let cont else { continue }
                if cont.controllerType != config.controllerType(for: index) {
                    cont.controllerType ?= config.controllerType(for: index)
                }
                
                cont.attach(index, controllerType: cont.controllerType)
            }
        }
    }
    
    
    private func selectedControllerIdsSnapshot() -> [String] {
        if Thread.isMainThread {
            return selectedControllers
        }
        
        return DispatchQueue.main.sync {
            selectedControllers
        }
    }
    
    func controllerAndIndexForString(_ id: String) -> (BaseController, Int)? {
        return controllerQueue.sync {
            guard let controller = _privAllControllers.first(where: { $0.id == id }),
                  let index = _privAllControllers.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            return (controller, index)
        }
    }
    
    func controllerForString(_ id: String) -> BaseController? {
        return controllerQueue.sync {
            return _privAllControllers.first(where: { $0.id == id })
        }
    }
    
    func firstControllerForName(_ name: String) -> BaseController? {
        return controllerQueue.sync {
            return _privAllControllers.first(where: { $0.nativeController?.vendorName ?? UUID().uuidString == name })
        }
    }
    
    func hasVirtualController() -> Bool {
        let selectedControllerIds = selectedControllerIdsSnapshot()
        
        return controllerQueue.sync {
            return selectedControllerIds.contains(_privAllControllers.first(where: { $0.virtual })?.id ?? "Failed to find virtual controller!")
        }
    }
    
    func initControllerObservers() {
        guard !didInitControllerObservers else { return }
        didInitControllerObservers = true
        
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.1) {
                self.refreshControllersList()
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.1) {
                self.refreshControllersList()
            }
        }
    }
    
    func toggleController(_ baseController: BaseController) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if let index = self.selectedControllers.firstIndex(where: { $0 == baseController.id }) {
                self.selectedControllers.remove(at: index)
            } else {
                self.selectedControllers.append(baseController.id)
            }
        }
    }
}
