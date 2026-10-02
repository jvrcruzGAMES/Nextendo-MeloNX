//
//  Color+Hex.swift
//  MeloNX
//
//  Created by Stossy11 on 8/6/2026.
//

import SwiftUI

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
    
    func toHex(includeAlpha: Bool = false) -> String? {
        guard let components = UIColor(self).cgColor.components,
              components.count >= 3 else { return nil }
        
        let r = Int(round(components[0] * 255))
        let g = Int(round(components[1] * 255))
        let b = Int(round(components[2] * 255))
        let a = components.count >= 4 ? Int(round(components[3] * 255)) : 255
        
        if includeAlpha {
            return String(format: "%02X%02X%02X%02X", a, r, g, b)
        } else {
            return String(format: "%02X%02X%02X", r, g, b)
        }
    }
}

extension UIColor {
    convenience init(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)
        self.init(
            red: CGFloat((rgb & 0xFF0000) >> 16) / 255,
            green: CGFloat((rgb & 0x00FF00) >> 8) / 255,
            blue: CGFloat(rgb & 0x0000FF) / 255,
            alpha: 1.0
        )
    }

    static func average(hexes: [String]) -> UIColor {
        let colors = hexes.map { UIColor(hex: $0) }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        for color in colors {
            var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0, ca: CGFloat = 0
            color.getRed(&cr, green: &cg, blue: &cb, alpha: &ca)
            r += cr; g += cg; b += cb; a += ca
        }
        let count = CGFloat(colors.count)
        return UIColor(red: r / count, green: g / count, blue: b / count, alpha: a / count)
    }
}
