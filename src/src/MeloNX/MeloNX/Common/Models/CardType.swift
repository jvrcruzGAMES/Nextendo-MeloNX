//
//  CardType.swift
//  MeloNX
//
//  Created by Stossy11 on 23/4/2026.
//

import SwiftUI

public enum CardType: Codable, CaseIterable {
    case list
    case card
    case compactCard
    case compactCardNoBackground
    case compactCardSmall
    case carousel

    var displayName: LocalizedStringKey {
        switch self {
        case .list: "List"
        case .card: "Card"
        case .compactCard: "Compact Card"
        case .compactCardNoBackground: "Compact Card (No Background)"
        case .compactCardSmall: "Compact Card (Small)"
        case .carousel: "3D Cartridge"
        }
    }
}

