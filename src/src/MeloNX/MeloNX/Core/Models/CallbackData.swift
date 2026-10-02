//
//  CallbackData.swift
//  MeloNX
//
//  Created by Stossy11 on 4/4/2026.
//

import Foundation

final class CallbackBox {
    let body: (CallbackData) -> Void
    init(_ body: @escaping (CallbackData) -> Void) { self.body = body }
}


extension CallbackData {
    var data: Data? {
        guard let ptr, len > 0 else { return nil }
        return Data(bytes: ptr, count: Int(len))
    }
    
    var string: String? {
        guard let data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    var bool: Bool? {
        guard let data, data.count >= 1 else { return nil }
        return data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return nil }
            return safeLoad(base, as: Swift.Bool.self)
        }
    }
    
    var int: Int32? {
        guard let data, data.count >= 4 else { return nil }
        return data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return nil }
            return safeLoad(base, as: Int32.self)
        }
    }
    
    var long: Int64? {
        guard let data, data.count >= 8 else { return nil }
        return data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return nil }
            return safeLoad(base, as: Int64.self)
        }
    }
    
    var float: Float? {
        guard let data, data.count >= 4 else { return nil }
        return data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return nil }
            return safeLoad(base, as: Swift.Float.self)
        }
    }
    
    var double: Double? {
        guard let data, data.count >= 8 else { return nil }
        return data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return nil }
            return safeLoad(base, as: Swift.Double.self)
        }
    }
    
    func load<T>(as type: T.Type) -> T? {
        guard let ptr, len > 0, Int(len) >= MemoryLayout<T>.size else { return nil }
        return safeLoad(ptr, as: T.self)
    }
}
