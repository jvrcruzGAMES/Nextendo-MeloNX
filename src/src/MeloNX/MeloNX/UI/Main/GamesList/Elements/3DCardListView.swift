//
//  3DCardListView.swift
//  MeloNX
//
//  Created by Stossy11 on 24/8/2026.
//

import SwiftUI
import SceneKit
import Combine

struct CartridgeData {
    let labelImage: UIImage
    let colors: [UIColor]
}

struct CartridgeCarouselView: UIViewRepresentable {
    var cartridges: [CartridgeData]
    @Binding var selectedIndex: Int
    
    var isPortraitiPhone: Bool {
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.interfaceOrientation
        
        return orientation?.isPortrait == true && UIDevice.current.userInterfaceIdiom == .phone
    }
    
    var spacing: Float {
        guard isPortraitiPhone else { return 40.0 }
        return 25.0
    }
    
    var uiMenu: (Int) -> UIMenu
    
    @Binding var spinTrigger: Int
    @Binding var reset: Bool
    
    
    var spun: (Int) -> Void = { _ in }
    
    var beforeUp: (Int) -> Void = { _ in }
    
    func makeCoordinator() -> Coordinator {
        let coord = Coordinator(self)
        return coord
    }
    
    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.allowsCameraControl = false
        scnView.autoenablesDefaultLighting = false
        scnView.backgroundColor = .clear
        
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        scnView.addGestureRecognizer(tapGesture)
        
        let contextMenuInteraction = UIContextMenuInteraction(delegate: context.coordinator)
        scnView.addInteraction(contextMenuInteraction)
        
        let scene = SCNScene()
        scnView.scene = scene
        
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        
        cameraNode.position = SCNVector3(Float(selectedIndex) * spacing, -4, isPortraitiPhone ? -70 : -50)
        cameraNode.eulerAngles = SCNVector3(0, Float.pi, 0)
        scene.rootNode.addChildNode(cameraNode)
        scnView.pointOfView = cameraNode
        
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.color = UIColor.white
        ambientLight.intensity = 700
        let ambientNode = SCNNode()
        ambientNode.light = ambientLight
        scene.rootNode.addChildNode(ambientNode)
        
        let whiteLight = SCNLight()
        whiteLight.type = .omni
        whiteLight.color = UIColor.white
        whiteLight.intensity = 550
        let whiteLightNode = SCNNode()
        whiteLightNode.name = "whiteLight"
        whiteLightNode.light = whiteLight
        cameraNode.addChildNode(whiteLightNode)

        let accentLight = SCNLight()
        accentLight.type = .omni
        
        if ThemeManager.shared.currentTheme == .defaultTheme {
            accentLight.color = UIColor.white
        } else {
            accentLight.color = UIColor(ThemeManager.shared.currentTheme.accent.primary)
        }
        accentLight.intensity = 1000
        accentLight.attenuationStartDistance = 10
        accentLight.attenuationEndDistance = 80
        let accentLightNode = SCNNode()
        accentLightNode.name = "themeTintLight"
        accentLightNode.light = accentLight
        accentLightNode.position = SCNVector3(0, 0, isPortraitiPhone ? 40 : 30)
        scene.rootNode.addChildNode(accentLightNode)
        
        if let baseScene = SCNScene(named: "cart.usdc") {
            for (index, item) in cartridges.enumerated() {
                let cartridgeNode = baseScene.rootNode.clone()
                
                cartridgeNode.enumerateHierarchy { node, _ in
                    if let geometry = node.geometry {
                        node.geometry = geometry.copy() as? SCNGeometry
                        node.geometry?.materials = geometry.materials.map {
                            $0.copy() as! SCNMaterial
                        }
                    }
                }
                
                cartridgeNode.position = SCNVector3(-Float(index) * spacing, 0, 0)
                cartridgeNode.name = "Cartridge_\(index)"
                cartridgeNode.setValue(
                    NSValue(scnVector3: cartridgeNode.position),
                    forKey: "originalPosition"
                )
                
                applyLabel(image: item.labelImage, to: cartridgeNode, materialName: "texture")
                
                applyColor(colors: item.colors, to: cartridgeNode, materialName: "Material_001")
                
                scene.rootNode.addChildNode(cartridgeNode)
            }
        }
        
        context.coordinator.parent = self
        context.coordinator.scnView = scnView
        context.coordinator.uiMenu = uiMenu
        
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.orientationChanged),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        
        return scnView
    }
    
    func updateUIView(_ scnView: SCNView, context: Context) {
        guard let cameraNode = scnView.pointOfView else { return }
        
        let targetX = -Float(selectedIndex) * spacing
        
        if context.coordinator.lastCameraTarget != selectedIndex {
            context.coordinator.lastCameraTarget = selectedIndex
            let moveAction = SCNAction.move(
                to: SCNVector3(targetX, cameraNode.position.y, cameraNode.position.z),
                duration: 0.35
            )
            moveAction.timingMode = .easeInEaseOut
            cameraNode.runAction(moveAction, forKey: "cameraMove")
            
            if let accentLightNode = scnView.scene?.rootNode.childNode(withName: "themeTintLight", recursively: false) {
                let moveAccent = SCNAction.move(
                    to: SCNVector3(targetX, accentLightNode.position.y, accentLightNode.position.z),
                    duration: 0.35
                )
                moveAccent.timingMode = .easeInEaseOut
                accentLightNode.runAction(moveAccent, forKey: "accentMove")
            }
        }
        
        if reset {
            DispatchQueue.main.async {
                reset = false
            }

            if let activeNode = scnView.scene?.rootNode.childNode(withName: "Cartridge_\(selectedIndex)", recursively: false),
               let originalPosition = activeNode.value(forKey: "originalPosition") as? NSValue {

                var targetPosition = originalPosition.scnVector3Value
                targetPosition.z -= 10

                context.coordinator.isSpinning = false
                let resetAction = SCNAction.move(to: targetPosition, duration: 0.4)
                resetAction.timingMode = .easeInEaseOut

                activeNode.runAction(resetAction, forKey: "reset")
            }
            return
        }

        if context.coordinator.lastSpinTrigger != spinTrigger {
            context.coordinator.lastSpinTrigger = spinTrigger
            context.coordinator.isSpinning = true
            
            let spinningIndex = selectedIndex

            if let activeNode = scnView.scene?.rootNode.childNode(withName: "Cartridge_\(spinningIndex)", recursively: false) {
                activeNode.removeAction(forKey: "spin")
                activeNode.removeAction(forKey: "selectedMove")
                guard let originalPosition = activeNode.value(forKey: "originalPosition") as? NSValue else {
                    return
                }

                let moveBack = SCNAction.move(to: originalPosition.scnVector3Value, duration: 0.4)
                moveBack.timingMode = .easeInEaseOut

                let spinAction = SCNAction.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 0.4)
                spinAction.timingMode = .easeInEaseOut

                let projected = scnView.projectPoint(activeNode.worldPosition)

                let targetScreenPoint = SCNVector3(
                    Float(scnView.bounds.midX),
                    Float(scnView.bounds.height),
                    projected.z
                )

                var targetWorldPoint = scnView.unprojectPoint(targetScreenPoint)
                targetWorldPoint.z = originalPosition.scnVector3Value.z
                targetWorldPoint.y -= 6

                var targetWorldPoint2 = targetWorldPoint
                targetWorldPoint2.y -= -1.5

                let moveDown = SCNAction.move(to: targetWorldPoint, duration: 0.4)
                moveDown.timingMode = .easeInEaseOut

                let moveUp = SCNAction.move(to: targetWorldPoint2, duration: 0.15)
                moveDown.timingMode = .easeInEaseOut

                let sequence = SCNAction.sequence([
                    moveBack,
                    SCNAction.wait(duration: 0.06),
                    spinAction,
                    SCNAction.wait(duration: 0.1),
                    moveDown,
                    SCNAction.run { node in
                        beforeUp(spinningIndex)
                    },
                    SCNAction.wait(duration: 0.08),
                    moveUp,
                    SCNAction.run { node in
                        context.coordinator.isSpinning = false
                        spun(spinningIndex)
                    }
                ])

                activeNode.runAction(sequence, forKey: "spin")
            }
        }

        for node in scnView.scene?.rootNode.childNodes ?? [] {
            guard let originalPosition = node.value(forKey: "originalPosition") as? NSValue else {
                continue
            }

            let position = originalPosition.scnVector3Value

            if node.name == "Cartridge_\(selectedIndex)" && !context.coordinator.isSpinning {
                if node.action(forKey: "reset") != nil { continue }

                let selectedPosition = SCNVector3(
                    position.x,
                    position.y,
                    position.z - 10
                )

                let moveCloser = SCNAction.move(
                    to: selectedPosition,
                    duration: 0.4
                )
                moveCloser.timingMode = .easeInEaseOut
                
                node.runAction(moveCloser, forKey: "selectedMove")

                continue
            }

            let moveBack = SCNAction.move(to: SCNVector3(node.position.x, node.position.y, position.z), duration: 0.4)
            moveBack.timingMode = .easeInEaseOut

            if node.action(forKey: "moveBack") == nil {
                node.runAction(moveBack, forKey: "moveBack")
            }
        }
    }

    class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var lastSpinTrigger: Int = 0
        var lastSelectedIndex: Int = 0
        var isSpinning: Bool = false
        var lastCameraTarget: Int? = nil
        var lastMenuIndex: Int? = nil
        var scnView: SCNView? = nil
        
        var uiMenu: (Int) -> UIMenu = { _ in UIMenu()}
        
        var parent: CartridgeCarouselView
        
        var themeCancellable: AnyCancellable?
        
        init(_ parent: CartridgeCarouselView) {
            self.parent = parent
            super.init()
            
            themeCancellable = ThemeManager.shared.$currentTheme
                .map { $0 == .defaultTheme ? UIColor.white : UIColor($0.accent.primary) }
                .removeDuplicates()
                .sink { [weak self] color in
                    self?.updateAmbientColor(color)
                }
        }
        
        func updateAmbientColor(_ color: UIColor) {
            guard let ambientNode = scnView?.scene?.rootNode
                .childNode(withName: "themeTintLight", recursively: false) else { return }
            
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.3
            ambientNode.light?.color = color
            SCNTransaction.commit()
        }
        
        @objc func orientationChanged() {
            guard let scnView, let cameraNode = scnView.pointOfView else { return }

            let newSpacing = parent.spacing
            let targetX = -Float(parent.selectedIndex) * newSpacing
            // let newCameraY: Float = parent.isPortraitiPhone ? -70 : -50
            
            for node in scnView.scene?.rootNode.childNodes ?? [] {
                guard let name = node.name, name.hasPrefix("Cartridge_"),
                      let index = Int(name.replacingOccurrences(of: "Cartridge_", with: "")),
                      let originalPosition = node.value(forKey: "originalPosition") as? NSValue else {
                    continue
                }
                
                let oldPos = originalPosition.scnVector3Value
                let newX = -Float(index) * newSpacing
                let newRestingPos = SCNVector3(newX, oldPos.y, oldPos.z)
                
                node.setValue(NSValue(scnVector3: newRestingPos), forKey: "originalPosition")
                
                let isSelected = (index == parent.selectedIndex) && !isSpinning
                let targetPos = isSelected ? SCNVector3(newRestingPos.x, newRestingPos.y, newRestingPos.z - 10) : SCNVector3(newRestingPos.x, node.position.y, newRestingPos.z)
                
                node.removeAction(forKey: "moveBack")
                node.removeAction(forKey: "selectedMove")
                
                let moveAction = SCNAction.move(to: targetPos, duration: 0.35)
                moveAction.timingMode = .easeInEaseOut
                node.runAction(moveAction, forKey: isSelected ? "selectedMove" : "moveBack")
            }
            
            
            if cameraNode.position.y != (parent.isPortraitiPhone ? -70 : -50) {
                let moveAction = SCNAction.move(
                    to: SCNVector3(targetX, cameraNode.position.y, parent.isPortraitiPhone ? -70 : -50),
                    duration: 0.35
                )
                moveAction.timingMode = .easeInEaseOut
                cameraNode.runAction(moveAction, forKey: "cameraMove")
            }
        }
        
        private func screenRect(for node: SCNNode, in scnView: SCNView) -> CGRect? {
            let (minB, maxB) = node.boundingBox
            let corners: [SCNVector3] = [
                SCNVector3(minB.x, minB.y, minB.z), SCNVector3(maxB.x, minB.y, minB.z),
                SCNVector3(minB.x, maxB.y, minB.z), SCNVector3(maxB.x, maxB.y, minB.z),
                SCNVector3(minB.x, minB.y, maxB.z), SCNVector3(maxB.x, minB.y, maxB.z),
                SCNVector3(minB.x, maxB.y, maxB.z), SCNVector3(maxB.x, maxB.y, maxB.z)
            ]
            
            var minPt = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
            var maxPt = CGPoint(x: -CGFloat.infinity, y: -CGFloat.infinity)
            
            for corner in corners {
                let worldPoint = node.convertPosition(corner, to: nil)
                let projected = scnView.projectPoint(worldPoint)
                let screenPoint = CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
                minPt.x = min(minPt.x, screenPoint.x)
                minPt.y = min(minPt.y, screenPoint.y)
                maxPt.x = max(maxPt.x, screenPoint.x)
                maxPt.y = max(maxPt.y, screenPoint.y)
            }
            
            guard minPt.x.isFinite, minPt.y.isFinite, maxPt.x.isFinite, maxPt.y.isFinite else { return nil }
            return CGRect(x: minPt.x, y: minPt.y, width: maxPt.x - minPt.x, height: maxPt.y - minPt.y)
        }
        
        private func cartridgeNode(at location: CGPoint, in sceneView: SCNView) -> (node: SCNNode, index: Int)? {
            let hitResults = sceneView.hitTest(location, options: nil)
            guard let firstResult = hitResults.first else { return nil }
            
            var node: SCNNode? = firstResult.node
            while node != nil, node?.name?.hasPrefix("Cartridge_") != true {
                node = node?.parent
            }
            guard let tappedNode = node,
                  let name = tappedNode.name,
                  let index = Int(name.replacingOccurrences(of: "Cartridge_", with: "")) else {
                return nil
            }
            return (tappedNode, index)
        }
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let sceneView = gesture.view as? SCNView else { return }
            let location = gesture.location(in: sceneView)
            guard let (_, index) = cartridgeNode(at: location, in: sceneView) else { return }
            
            if index == parent.selectedIndex {
                parent.spinTrigger += 1
            } else {
                parent.selectedIndex = index
            }
        }
        
        func contextMenuInteraction(_ interaction: UIContextMenuInteraction, previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
            guard let sceneView = interaction.view as? SCNView,
                  let index = lastMenuIndex,
                  let node = sceneView.scene?.rootNode.childNode(withName: "Cartridge_\(index)", recursively: false),
                  let rect = screenRect(for: node, in: sceneView) else { return nil }
            
            let snapshotImage = sceneView.snapshot()
            let imageView = UIImageView(image: snapshotImage)
            imageView.frame = sceneView.bounds
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            
            let parameters = UIPreviewParameters()
            parameters.visiblePath = UIBezierPath(roundedRect: rect, cornerRadius: 12)
            parameters.backgroundColor = .clear
            
            let target = UIPreviewTarget(container: sceneView, center: CGPoint(x: rect.midX, y: rect.midY))
            return UITargetedPreview(view: imageView, parameters: parameters, target: target)
        }
        
        func contextMenuInteraction(_ interaction: UIContextMenuInteraction, previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
            contextMenuInteraction(interaction, previewForHighlightingMenuWithConfiguration: configuration)
        }
        
        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard let sceneView = interaction.view as? SCNView,
                  let (_, index) = cartridgeNode(at: location, in: sceneView) else { return nil }
            
            lastMenuIndex = index
            
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                self?.uiMenu(index)
            }
        }
    }
    
    private func applyLabel(image: UIImage, to parentNode: SCNNode, materialName: String) {
        parentNode.enumerateHierarchy { node, _ in
            guard let materials = node.geometry?.materials else { return }
            for material in materials where material.name == materialName {
                material.diffuse.contents = image.withRoundedCorners(radius: 12)
            }
        }
    }
    
    private func applyColor(colors: [UIColor], to parentNode: SCNNode, materialName: String) {
        parentNode.enumerateHierarchy { node, _ in
            guard let materials = node.geometry?.materials else { return }
            var index = 0
            for material in materials where material.name == materialName {
                if index < colors.count {
                    material.diffuse.contents = colors[index]
                    
                    material.lightingModel = .physicallyBased
                    
                    material.roughness.contents = 0.75
                    material.metalness.contents = 0.0
                    
                    material.ambient.contents = UIColor(white: 0.35, alpha: 1.0)
                    
                    index += 1
                }
            }
        }
    }
}


extension UIImage {
    func withRoundedCorners(radius: CGFloat) -> UIImage? {
        let rect = CGRect(origin: .zero, size: self.size)
        
        let renderer = UIGraphicsImageRenderer(size: self.size)
        
        return renderer.image { context in
            let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
            path.addClip()
            
            self.draw(in: rect)
        }
    }
    
    func toCircle() -> UIImage? {
        let minSide = min(self.size.width, self.size.height)
        let rect = CGRect(x: (self.size.width - minSide) / 2,
                          y: (self.size.height - minSide) / 2,
                          width: minSide,
                          height: minSide)
        
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: minSide, height: minSide))
        
        return renderer.image { context in
            let path = UIBezierPath(ovalIn: CGRect(origin: .zero, size: CGSize(width: minSide, height: minSide)))
            path.addClip()
            
            self.draw(in: CGRect(x: -rect.origin.x, y: -rect.origin.y, width: self.size.width, height: self.size.height))
        }
    }
}
