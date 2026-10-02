//
//  NativeController.swift
//  MeloNX
//
//  Created by Stossy11 on 19/10/2025.
//

import Foundation
import CoreHaptics
import UIKit
import GameController
import Melo_Controller


class NativeController: BaseController {
    override init(nativeController: GCController?, virtual: Bool? = nil) {
        super.init(nativeController: nativeController)
    }
    
    var count = 0
    
    override public func setupController() {
        if let gamepad = nativeController?.extendedGamepad {
            
            nativeController?.handlerQueue = inputQueue
            
            setupButtonChangeListener(gamepad.buttonA, for: UserDefaults.standard.bool(forKey: "swapBandA") ? .B : .A)
            setupButtonChangeListener(gamepad.buttonB, for: UserDefaults.standard.bool(forKey: "swapBandA") ? .A : .B)
            setupButtonChangeListener(gamepad.buttonX, for: UserDefaults.standard.bool(forKey: "swapBandA") ? .Y : .X)
            setupButtonChangeListener(gamepad.buttonY, for: UserDefaults.standard.bool(forKey: "swapBandA") ? .X : .Y)
            
            setupButtonChangeListener(gamepad.dpad.up, for: .dPadUp)
            setupButtonChangeListener(gamepad.dpad.down, for: .dPadDown)
            setupButtonChangeListener(gamepad.dpad.left, for: .dPadLeft)
            setupButtonChangeListener(gamepad.dpad.right, for: .dPadRight)
            
            setupButtonChangeListener(gamepad.leftShoulder, for: .leftShoulder)
            setupButtonChangeListener(gamepad.rightShoulder, for: .rightShoulder)
            gamepad.leftThumbstickButton.map { setupButtonChangeListener($0, for: .leftStick) }
            gamepad.rightThumbstickButton.map { setupButtonChangeListener($0, for: .rightStick) }
            
            setupButtonChangeListener(gamepad.buttonMenu, for: .start)
            gamepad.buttonOptions.map { setupButtonChangeListener($0, for: .back) }
            
            setupStickChangeListener(gamepad.leftThumbstick, for: .left)
            setupStickChangeListener(gamepad.rightThumbstick, for: .right)
            
            setupTriggerChangeListener(gamepad.leftTrigger, for: .left)
            setupTriggerChangeListener(gamepad.rightTrigger, for: .right)
        } else if let profile = nativeController?.physicalInputProfile {
            let swapAB = UserDefaults.standard.bool(forKey: "swapBandA")
            
            if let a = profile.buttons[GCInputButtonA] {
                setupButtonChangeListener(a, for: swapAB ? .B : .A)
            }
            if let b = profile.buttons[GCInputButtonB] {
                setupButtonChangeListener(b, for: swapAB ? .A : .B)
            }
            if let x = profile.buttons[GCInputButtonX] {
                setupButtonChangeListener(x, for: swapAB ? .Y : .X)
            }
            if let y = profile.buttons[GCInputButtonY] {
                setupButtonChangeListener(y, for: swapAB ? .X : .Y)
            }
            
            if let dpad = profile.dpads[GCInputDirectionPad] {
                setupButtonChangeListener(dpad.up, for: .dPadUp)
                setupButtonChangeListener(dpad.down, for: .dPadDown)
                setupButtonChangeListener(dpad.left, for: .dPadLeft)
                setupButtonChangeListener(dpad.right, for: .dPadRight)
            }
            
            if let leftShoulder = profile.buttons[GCInputLeftShoulder] {
                setupButtonChangeListener(leftShoulder, for: .leftShoulder)
            }
            if let rightShoulder = profile.buttons[GCInputRightShoulder] {
                setupButtonChangeListener(rightShoulder, for: .rightShoulder)
            }
            if let leftStick = profile.buttons[GCInputLeftThumbstickButton] {
                setupButtonChangeListener(leftStick, for: .leftStick)
            }
            if let rightStick = profile.buttons[GCInputRightThumbstickButton] {
                setupButtonChangeListener(rightStick, for: .rightStick)
            }
            
            if let menu = profile.buttons[GCInputButtonMenu] {
                setupButtonChangeListener(menu, for: .start)
            }
            if let options = profile.buttons[GCInputButtonOptions] {
                setupButtonChangeListener(options, for: .back)
            }
            
            if let leftThumbstick = profile.dpads[GCInputLeftThumbstick] {
                setupStickChangeListener(leftThumbstick, for: .left)
            }
            if let rightThumbstick = profile.dpads[GCInputRightThumbstick] {
                setupStickChangeListener(rightThumbstick, for: .right)
            }
            
            if let leftTrigger = profile.buttons[GCInputLeftTrigger] {
                setupTriggerChangeListener(leftTrigger, for: .left)
            }
            if let rightTrigger = profile.buttons[GCInputRightTrigger] {
                setupTriggerChangeListener(rightTrigger, for: .right)
            }
            
        }
        
        /*
        gamepad.buttonHome?.valueChangedHandler = { [unowned self] _, _, pressed in
            if pressed {
                count += 1
                
                if count == 2 {
                    count = 0
                    
                    
                }
            }
        }
         */
        

        setupHaptics()
        
        setupMotion()
    }
    
    func setupButtonChangeListener(_ button: GCControllerButtonInput, for key: VirtualControllerButton) {
        button.valueChangedHandler = { [weak self] _, _, pressed in
            guard let self else { return }
            setButtonState(pressed ? 1 : 0, for: key)
        }
    }

    func setupStickChangeListener(_ button: GCControllerDirectionPad, for key: ThumbstickType) {
        button.valueChangedHandler = { [weak self] _, xValue, yValue in
            guard let self else { return }
            
            switch key {
            case .left:
                updateAxisValue(x: xValue, y: yValue, forAxis: 1)
            case .right:
                updateAxisValue(x: xValue, y: yValue, forAxis: 2)
            }
        }
    }

    func setupTriggerChangeListener(_ button: GCControllerButtonInput, for key: ThumbstickType) {
        button.valueChangedHandler = { [weak self] _, _, pressed in
            guard let self else { return }
            setButtonState(pressed ? 1 : 0, for: key == .left ? .leftTrigger : .rightTrigger)
        }
    }
    
    override func cleanup() {
        clearInputHandlers()

        super.cleanup()
    }
    
    private func clearInputHandlers() {
        guard let gamepad = nativeController?.extendedGamepad else { return }
        
        gamepad.buttonA.valueChangedHandler = nil
        gamepad.buttonB.valueChangedHandler = nil
        gamepad.buttonX.valueChangedHandler = nil
        gamepad.buttonY.valueChangedHandler = nil
        gamepad.dpad.up.valueChangedHandler = nil
        gamepad.dpad.down.valueChangedHandler = nil
        gamepad.dpad.left.valueChangedHandler = nil
        gamepad.dpad.right.valueChangedHandler = nil
        gamepad.leftShoulder.valueChangedHandler = nil
        gamepad.rightShoulder.valueChangedHandler = nil
        gamepad.leftThumbstickButton?.valueChangedHandler = nil
        gamepad.rightThumbstickButton?.valueChangedHandler = nil
        gamepad.buttonMenu.valueChangedHandler = nil
        gamepad.buttonOptions?.valueChangedHandler = nil
        gamepad.leftThumbstick.valueChangedHandler = nil
        gamepad.rightThumbstick.valueChangedHandler = nil
        gamepad.leftTrigger.valueChangedHandler = nil
        gamepad.rightTrigger.valueChangedHandler = nil
        gamepad.buttonHome?.valueChangedHandler = nil
    }
}
