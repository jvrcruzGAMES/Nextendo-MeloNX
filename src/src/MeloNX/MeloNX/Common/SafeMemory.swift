//
//  SafeMemory.swift
//  MeloNX
//

import Foundation

@inline(__always)
func safeLoad<T>(_ ptr: UnsafeRawPointer, as type: T.Type) -> T {
    var val = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { val.deallocate() }
    val.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<T>.size) { dest in
        let src = ptr.assumingMemoryBound(to: UInt8.self)
        dest.initialize(from: src, count: MemoryLayout<T>.size)
    }
    return val.pointee
}
