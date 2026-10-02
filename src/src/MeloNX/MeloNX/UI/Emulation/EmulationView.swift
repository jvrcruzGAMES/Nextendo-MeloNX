//
//  EmulationView.swift
//  MeloNX
//
//  Created by Stossy11 on 23/4/2026.
//

import SwiftUI
import Melo_Controller
import Combine

@MainActor
class MemoryUsageMonitor: ObservableObject {
    @Published private(set) var memoryUsage: UInt64 = 0
    private var task: Task<Void, Never>?

    init() {
        task = Task {
            await monitorMemoryUsage()
        }
    }

    deinit {
        task?.cancel()
    }

    private func monitorMemoryUsage() async {
        while !Task.isCancelled {
            updateMemoryUsage()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func updateMemoryUsage() {
        var taskInfo = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride) / 4

        let result: kern_return_t = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }

        if result == KERN_SUCCESS {
            memoryUsage = taskInfo.phys_footprint
        } else {
            print("Failed to get memory usage: \(result)")
            memoryUsage = 0
        }
    }

    func formatMemorySize(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
    }
}


struct EmulationView: View {
    var game: GameInfo
    @EnvironmentObject var ryujinxController: RyujinxController
    @ObservedObject var menuViewHandler: InGameConfigView_MenuView = .shared
    @StateObject var controllerManager: ControllerManager = .shared
    @StateObject var statisticsHandler: StatisticsHandler = .init()
    @StateObject private var nativeSettingsManager: NativeSettingsManager = .shared
    private var air = Air.shared
    
    @State var isConnected = false
    
    init(game: GameInfo) {
        self.game = game
    }
    
    @ViewBuilder
    func emulationView(_ airplay: Bool = false) -> some View {
        if airplay { MetalViewRepresentable(showView: true).ignoresSafeArea().frame(maxWidth: .infinity, maxHeight: .infinity) } else {
            MetalViewContainer(showView: !isConnected, airplay: airplay, ryujinxController: ryujinxController, statisticsHandler: statisticsHandler, nativeSettingsManager: nativeSettingsManager)
                .overlay {
                    if controllerManager.hasVirtualController() && !airplay {
                        ControllerView(controller: VirtualControllerManager.shared, isEditing: false, gameId: game.titleId)
                            .ignoresSafeArea(.all, edges: .vertical)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    var body: some View {
        Group {
            emulationView()
                .onAppear() {
                    statisticsHandler.registerPush()
                    
                    self.isConnected = Air.shared.connected
                    Air.shared.connectionCallbacks.append { self.isConnected = $0 }
                    
                    Air.play(AnyView(emulationView(true)))
                }
                .if(!statisticsHandler.started) { view in
                    view
                        .overlay {
                            LoadingOverlayView(game:  game, showLogs: false)
                                .onDisappear() {
                                    menuViewHandler.triggerButton()
                                }
                        }
                }
        }
    }
}
