import Foundation
#if !os(macOS)
import os
#endif

/// Memory heavy work may plan for. On macOS that is the machine's RAM, as the system pages; iOS gives each app a
/// limit of its own and ends it on reaching that, so there it is what the app may still allocate.
enum MemoryBudget {
    static var bytes: Double {
        #if os(macOS)
        Double(ProcessInfo.processInfo.physicalMemory)
        #else
        Double(os_proc_available_memory())
        #endif
    }
}
