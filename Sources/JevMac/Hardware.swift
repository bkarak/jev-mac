import Darwin
import Foundation
import IOKit
import IOKit.ps

/// The machine a measurement ran on, and the conditions at the time. Chip,
/// cores, memory and OS fix the ceiling; power source, Low Power Mode,
/// thermal state, load and memory pressure decide how close a run gets to it.
public struct Hardware: Sendable {
    public let model: String
    public let chip: String
    public let cpuCores: Int
    public let performanceCores: Int?
    public let efficiencyCores: Int?
    public let gpuCores: Int?
    public let memoryBytes: UInt64
    public let osVersion: String
    public let osBuild: String
    public let power: String
    public let lowPowerMode: Bool
    public let thermalState: String
    public let loadAverage: Double
    public let memoryPressure: String?

    public static func current() -> Hardware {
        let info = ProcessInfo.processInfo
        var loads = [0.0, 0.0, 0.0]
        let loaded = getloadavg(&loads, 3) > 0
        return Hardware(
            model: sysctlString("hw.model") ?? "unknown Mac",
            chip: sysctlString("machdep.cpu.brand_string") ?? "unknown chip",
            cpuCores: sysctlInt("hw.physicalcpu") ?? info.activeProcessorCount,
            performanceCores: sysctlInt("hw.perflevel0.physicalcpu"),
            efficiencyCores: sysctlInt("hw.perflevel1.physicalcpu"),
            gpuCores: gpuCoreCount(),
            memoryBytes: info.physicalMemory,
            osVersion: sysctlString("kern.osproductversion") ?? info.operatingSystemVersionString,
            osBuild: sysctlString("kern.osversion") ?? "",
            power: powerSource(),
            lowPowerMode: info.isLowPowerModeEnabled,
            thermalState: describe(info.thermalState),
            loadAverage: loaded ? loads[0] : -1,
            memoryPressure: sysctlInt("kern.memorystatus_vm_pressure_level").map(describePressure)
        )
    }

    /// "Apple M4 Max (Mac16,5) · 16 CPU cores (12 performance + 4 efficiency) · 40 GPU cores · 64 GB memory"
    public var machine: String {
        var cores = "\(cpuCores) CPU cores"
        if let p = performanceCores, let e = efficiencyCores { cores += " (\(p) performance + \(e) efficiency)" }
        var parts = ["\(chip) (\(model))", cores]
        if let g = gpuCores { parts.append("\(g) GPU cores") }
        parts.append(Hardware.formatMemory(memoryBytes) + " memory")
        return parts.joined(separator: " · ")
    }

    /// "macOS 27.0 (26A428) · AC power (battery 80%) · Low Power Mode off · thermal nominal · load 2.14 · memory pressure normal"
    public var conditions: String {
        var parts = ["macOS \(osVersion)" + (osBuild.isEmpty ? "" : " (\(osBuild))"), power,
                     "Low Power Mode \(lowPowerMode ? "on" : "off")", "thermal \(thermalState)"]
        if loadAverage >= 0 { parts.append(String(format: "load %.2f", loadAverage)) }
        if let m = memoryPressure { parts.append("memory pressure \(m)") }
        return parts.joined(separator: " · ")
    }

    /// The parts that can drift during a long run.
    public var drift: String {
        [power, "thermal \(thermalState)", loadAverage >= 0 ? String(format: "load %.2f", loadAverage) : nil,
         memoryPressure.map { "memory pressure \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    /// Conditions that make timings slower or noisier than the machine allows.
    public var warnings: [String] {
        var w: [String] = []
        let busy = Double(performanceCores ?? cpuCores) / 2
        if loadAverage > busy { w.append(String(format: "the machine is busy (load %.1f); close other work for representative timings", loadAverage)) }
        if power.hasPrefix("battery") { w.append("running on battery; macOS may lower performance") }
        if lowPowerMode { w.append("Low Power Mode is on; timings will be slower") }
        if thermalState != "nominal" { w.append("thermal state is \(thermalState); the chip may be throttled") }
        if let m = memoryPressure, m != "normal" { w.append("memory pressure is \(m)") }
        return w
    }

    public static func formatMemory(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 1 ? String(format: gb == gb.rounded() ? "%.0f GB" : "%.1f GB", gb)
                       : String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    // MARK: Sources

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let s = String(cString: buffer).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return size == 4 ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }

    static func gpuCoreCount() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? NSNumber)?.intValue
    }

    static func powerSource() -> String {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return "power source unknown" }
        let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        var text = type == kIOPMACPowerKey ? "AC power" : type == kIOPMBatteryPowerKey ? "battery power" : (type ?? "power source unknown")
        let sources = (IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]) ?? []
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            text += " (battery \(current * 100 / max)%)"
        }
        return text
    }

    static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious (throttling likely)"
        case .critical: "critical (throttling)"
        @unknown default: "unknown"
        }
    }

    static func describePressure(_ level: Int) -> String {
        switch level {
        case 1: "normal"
        case 2: "warning"
        case 4: "critical"
        default: "level \(level)"
        }
    }
}
