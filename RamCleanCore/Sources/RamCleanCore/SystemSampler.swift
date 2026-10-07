import Darwin
import Foundation

public enum MemoryPressure: Int, Codable, Sendable {
    case normal = 1, warning = 2, critical = 4

    public var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Elevated"
        case .critical: return "Critical"
        }
    }
}

/// Whole-machine numbers: RAM, swap, memory pressure, total CPU and free disk.
public struct SystemSnapshot: Sendable, Equatable {
    public var totalMemory: UInt64
    public var usedMemory: UInt64
    public var compressedMemory: UInt64
    public var swapUsed: UInt64
    public var pressure: MemoryPressure
    /// 0–100 across all cores.
    public var cpuPercent: Double
    public var diskTotal: Int64
    public var diskFree: Int64

    public init(totalMemory: UInt64, usedMemory: UInt64, compressedMemory: UInt64 = 0, swapUsed: UInt64 = 0,
                pressure: MemoryPressure = .normal, cpuPercent: Double = 0, diskTotal: Int64 = 1, diskFree: Int64 = 1) {
        self.totalMemory = totalMemory; self.usedMemory = usedMemory; self.compressedMemory = compressedMemory
        self.swapUsed = swapUsed; self.pressure = pressure; self.cpuPercent = cpuPercent
        self.diskTotal = diskTotal; self.diskFree = diskFree
    }

    public var memoryUsedFraction: Double {
        totalMemory == 0 ? 0 : min(1, Double(usedMemory) / Double(totalMemory))
    }
    public var diskFreeFraction: Double {
        diskTotal <= 0 ? 1 : Double(diskFree) / Double(diskTotal)
    }
}

public final class SystemSampler {
    private var lastTicks: [UInt32]?

    public init() {}

    public func sample() -> SystemSnapshot {
        let host = mach_host_self()
        var pageSize: vm_size_t = 0
        host_page_size(host, &pageSize)
        let page = UInt64(pageSize)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var used: UInt64 = 0, compressed: UInt64 = 0
        if kr == KERN_SUCCESS {
            // Matches Activity Monitor's "Memory Used": app memory + wired + compressed.
            let app = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
            compressed = UInt64(stats.compressor_page_count) * page
            used = (app + UInt64(stats.wire_count)) * page + compressed
        }

        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)

        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)

        var diskTotal: Int64 = 0, diskFree: Int64 = 0
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            diskTotal = Int64(v.volumeTotalCapacity ?? 0)
            diskFree = v.volumeAvailableCapacityForImportantUsage ?? 0
        }

        return SystemSnapshot(
            totalMemory: ProcessInfo.processInfo.physicalMemory,
            usedMemory: used, compressedMemory: compressed, swapUsed: swap.xsu_used,
            pressure: MemoryPressure(rawValue: Int(level)) ?? .normal,
            cpuPercent: cpuPercent(host), diskTotal: diskTotal, diskFree: diskFree)
    }

    private func cpuPercent(_ host: mach_port_t) -> Double {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let t = load.cpu_ticks
        let ticks = [t.0, t.1, t.2, t.3] // user, system, idle, nice
        defer { lastTicks = ticks }
        guard let prev = lastTicks else { return 0 }
        let d = zip(ticks, prev).map { Double($0 &- $1) }
        let total = d.reduce(0, +)
        return total > 0 ? (total - d[2]) / total * 100 : 0
    }
}
