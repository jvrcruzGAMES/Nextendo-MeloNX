//
//  MemoryLimitManager.swift
//  MeloNX
//
//  Created by Stossy11 on 30/7/2026.
//

// this was a pretty highly requested feature, ever since autumn left and RAMBench hasn't been updated

import SwiftUI
import Combine

class MemoryLimitManager: ObservableObject {
    @Published var memoryLimit: UInt64 = 0
    @Published var started: Bool = false
    
    var stopRun: Bool = false
    
    
    nonisolated var userDefaultsMemoryLimit: UInt64 {
        get {
            (UserDefaults.standard.value(forKey: "memoryLimit") as? NSNumber)?.uint64Value ?? 0
        } set {
            UserDefaults.standard.set(NSNumber(value: newValue), forKey: "memoryLimit")
        }
    }
    
    init() {
        memoryLimit = userDefaultsMemoryLimit
    }
    
    
    func testRAMLimit(chunkSizeMB: Int = 128)  {
        self.started = true
        
        Thread.detachNewThread {
            let chunkSize = chunkSizeMB * 1024 * 1024
            
            var allocations: [UnsafeMutableRawPointer] = []
            var totalAllocated: UInt64 = 0
            
            var isContinuing: Bool = true
            
            while isContinuing {
                guard let ptr = malloc(chunkSize) else {
                    print("malloc failed at \(totalAllocated / 1024 / 1024) MB allocated")
                    break
                }
                
                totalAllocated += UInt64(chunkSize)
                
                if self.stopRun {
                    for ptr in allocations {
                        free(ptr)
                    }
                    
                    DispatchQueue.main.async {
                        self.started = false
                        self.stopRun = false
                    }
                    
                    isContinuing = false
                } else {
                    DispatchQueue.main.async {
                        self.userDefaultsMemoryLimit = totalAllocated
                        self.memoryLimit = totalAllocated
                        
                        print("Allocated: \(self.memoryLimit / 1024 / 1024) MB")
                    }
                }
                
    
                memset(ptr, Int32.random(in: 1...255), chunkSize)
                
                allocations.append(ptr)
                
                self.threadSleep(nanoseconds: 500_000_000)
            }
        }
    }
    
    func stop() {
        self.userDefaultsMemoryLimit = 0
        self.memoryLimit = 0
        
        stopRun = true
    }
    
    func formatMemorySize() -> String {
        let gb = Double(memoryLimit) / 1024 / 1024 / 1024
        return String(format: "%.2f GB", gb)
    }
    
    @inline(__always)
    func threadSleep(nanoseconds: Int) {
        var spec = timespec(tv_sec: nanoseconds / 1_000_000_000,
                            tv_nsec: nanoseconds % 1_000_000_000)
        nanosleep(&spec, nil)
    }

}
