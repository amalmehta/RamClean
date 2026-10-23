import Darwin
import Foundation

/// One process, as seen in one sample.
public struct ProcessSnapshot: Sendable, Equatable {
    public var pid: Int32
    public var ppid: Int32
    public var uid: UInt32
    public var name: String
    public var path: String
    public var footprintBytes: UInt64
    /// Percent of one core used since the previous sample (0 on the first sample). A process
    /// started since then gets its average over its short life, so a compile step that began
    /// a few seconds ago doesn't read as idle.
    public var cpuPercent: Double
    /// True when the process has a controlling terminal (it was started from a shell).
    public var hasTTY: Bool

    public init(pid: Int32, ppid: Int32, uid: UInt32 = 501, name: String, path: String,
                footprintBytes: UInt64, cpuPercent: Double = 0, hasTTY: Bool = false) {
        self.pid = pid; self.ppid = ppid; self.uid = uid; self.name = name; self.path = path
        self.footprintBytes = footprintBytes; self.cpuPercent = cpuPercent; self.hasTTY = hasTTY
    }
}

/// Reads every process this user can see through libproc. Processes owned by other
/// users (root daemons) can't be read without privileges and are skipped; they
/// can't be quit by RamClean anyway.
public final class ProcessSampler {
    private struct CPUMark { let start: UInt64; let cpuNs: UInt64 }
    private var lastCPU: [Int32: CPUMark] = [:]
    private var lastSampleNs: UInt64 = 0
    private let numer: UInt64
    private let denom: UInt64

    public init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        numer = UInt64(tb.numer); denom = UInt64(max(tb.denom, 1))
    }

    public func sample() -> [ProcessSnapshot] {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = lastSampleNs == 0 ? 0 : now - lastSampleNs
        let wallNow = Date().timeIntervalSince1970
        lastSampleNs = now

        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 128)
        let count = pids.withUnsafeMutableBytes { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count))
        }
        guard count > 0 else { return [] }

        var result: [ProcessSnapshot] = []
        var marks: [Int32: CPUMark] = [:]
        result.reserveCapacity(Int(count))
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)

        for pid in pids.prefix(Int(count)) where pid > 0 {
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { continue }

            var ru = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &ru) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard rc == 0 else { continue }

            let plen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            let path = plen > 0 ? String(cString: pathBuf) : ""
            var name = Self.string(from: &bsd.pbi_name)
            if name.isEmpty { name = Self.string(from: &bsd.pbi_comm) }

            let cpuNs = (ru.ri_user_time + ru.ri_system_time) * numer / denom
            var cpuPercent = 0.0
            if elapsed > 0, let prev = lastCPU[pid], prev.start == bsd.pbi_start_tvsec, cpuNs >= prev.cpuNs {
                cpuPercent = Double(cpuNs - prev.cpuNs) / Double(elapsed) * 100
            } else if elapsed > 0 {
                let age = wallNow - (Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1_000_000)
                if age >= 0.5, age <= Double(elapsed) / 1e9 + 1 { cpuPercent = Double(cpuNs) / 1e9 / age * 100 }
            }
            marks[pid] = CPUMark(start: bsd.pbi_start_tvsec, cpuNs: cpuNs)

            result.append(ProcessSnapshot(
                pid: pid, ppid: Int32(bsd.pbi_ppid), uid: bsd.pbi_uid, name: name, path: path,
                footprintBytes: ru.ri_phys_footprint, cpuPercent: cpuPercent,
                hasTTY: (bsd.pbi_flags & 0x2) != 0 // PROC_FLAG_CONTROLT
            ))
        }
        lastCPU = marks
        return result
    }

    private static func string<T>(from tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
