//
//  ControllerRow.swift
//  MeloNX
//
//  Created by Stossy11 on 10/11/2025.
//

import SwiftUI

struct ControllerRow: View {
    let index: Int
    let controllerId: String
    @ObservedObject var controllerManager: ControllerManager
    @EnvironmentObject var ryujinxController: RyujinxController

    private var controller: BaseController? {
        controllerManager.controllerAndIndexForString(controllerId)?.0
    }

    private var controllerIndex: Int? {
        controllerManager.controllerAndIndexForString(controllerId)?.1
    }

    var body: some View {
        guard let controller else { return AnyView(EmptyView()) }

        return AnyView(
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "gamecontroller.fill")
                        .foregroundColor(.accentColor)

                    Text("Player \(index + 1): \(controller.name)")
                        .lineLimit(1)

                    Spacer()

                    Button {
                        controllerManager.toggleController(controller)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 8)

            }
            .contextMenu {
                ForEach(ControllerType.allCases) { type in
                    if controller.controllerType == type {
                        Button {
                            controller.controllerType = type
                        } label: {
                            Label(type.displayName, systemImage: "checkmark")
                        }
                    } else {
                        Button(type.displayName) {
                            controller.controllerType = type
                            Options.updateControllerType(index: index, to: controller.controllerType, options: &ryujinxController.settings)
                            
                        }
                        .tag(type.rawValue)
                    }
                }
            }
        )
    }
}
