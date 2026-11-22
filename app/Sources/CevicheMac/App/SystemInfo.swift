import Foundation
import Metal
import Darwin
import CevicheCore

/// A manually refreshed capability snapshot, not a system-load monitor.
struct SystemInfo: Sendable {
    let model: String?
    let cpu: String?
    let logicalCPUs: Int
    let architecture: String
    let osVersion: OperatingSystemVersion
    let ram: UInt64
    let gpu: String?
    let metalReady: Bool
    let unifiedMemory: Bool?
    let gpuBudget: UInt64?
    let maxBuffer: UInt64?
    let modelsFound: Int
    let appVersion: String

    var meetsRequirements: Bool { osVersion.majorVersion >= 15 && metalReady }
    /// Advisory thresholds, not additional minimum requirements or benchmark results.
    var limitedRAM: Bool { ram < 8 * 1_073_741_824 }
    var limitedGPU: Bool { gpuBudget.map { $0 < 2 * 1_073_741_824 } ?? false }
    var diagnosis: [String] {
        var notes: [String] = []
        if osVersion.majorVersion < 15 { notes.append(L10n.tr("macOS 15 or later is required.")) }
        if !metalReady { notes.append(L10n.tr("A working Metal GPU is required for photo rendering.")) }
        if limitedRAM { notes.append(L10n.tr("Limited RAM. Large images and multi-frame tools may need smaller batches.")) }
        if limitedGPU { notes.append(L10n.tr("Limited GPU budget. Reduce preview size or the number of frames.")) }
        if metalReady && gpuBudget == nil { notes.append(L10n.tr("Metal did not report a GPU memory budget.")) }
        if notes.isEmpty { notes.append(L10n.tr("No hardware limitations detected by these checks.")) }
        return notes
    }

    static func capture() -> Self {
        let process = ProcessInfo.processInfo
        let device = MTLCreateSystemDefaultDevice()
        let architecture = "arm64"
        func positive(_ value: UInt64?) -> UInt64? { value.flatMap { $0 > 0 ? $0 : nil } }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return Self(model: string("hw.model"), cpu: string("machdep.cpu.brand_string"), logicalCPUs: process.processorCount,
                    architecture: architecture, osVersion: process.operatingSystemVersion, ram: process.physicalMemory,
                    gpu: device?.name, metalReady: device?.makeCommandQueue() != nil,
                    unifiedMemory: device?.hasUnifiedMemory, gpuBudget: positive(device?.recommendedMaxWorkingSetSize),
                    maxBuffer: positive(device.map { UInt64($0.maxBufferLength) }),
                    modelsFound: BundledModel.allCases.filter(\.isAvailable).count,
                    appVersion: build.map { "\(version) (\($0))" } ?? version)
    }

    private static func string(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }
    static func memory(_ bytes: UInt64?) -> String {
        guard let bytes else { return L10n.tr("Not reported") }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }
    var systemVersion: String { "macOS \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)" }
    var memoryType: String {
        switch unifiedMemory {
        case true: return L10n.tr("Unified · shared with CPU")
        case false: return L10n.tr("Dedicated GPU memory")
        case nil: return L10n.tr("Not reported")
        }
    }
    /// Includes no user name, serial number, catalog path, or photo metadata.
    var report: String {
        let rows = [
            ("Ceviche", appVersion), (L10n.tr("Mac"), model ?? "—"),
            (L10n.tr("System"), systemVersion), ("CPU", cpu ?? architecture),
            (L10n.tr("Architecture"), architecture), (L10n.tr("CPU threads"), String(logicalCPUs)),
            ("RAM", Self.memory(ram)), ("GPU", gpu ?? L10n.tr("Not reported")),
            (L10n.tr("GPU memory"), memoryType), (L10n.tr("Metal budget"), Self.memory(gpuBudget)),
            (L10n.tr("Max buffer"), Self.memory(maxBuffer)),
            (L10n.tr("AI models found"), "\(modelsFound)/\(BundledModel.allCases.count)")
        ]
        return rows.map { "\($0.0): \($0.1)" }.joined(separator: "\n") + "\n\n" + diagnosis.joined(separator: "\n")
            + "\n\n" + L10n.tr("Metal budget is not free VRAM. Unified memory is shared with the CPU.")
    }
}
