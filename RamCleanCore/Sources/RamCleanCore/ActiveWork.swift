import Foundation

/// Why an app is in the middle of something right now. A busy app is never suggested.
public enum ActiveWorkReason: Equatable, Sendable {
    /// A compiler, bundler or build driver in its process tree has been working.
    case building(tool: String)
    /// Claude Code inside it is running commands or tools.
    case agentRunning
    case playingAudio
    /// It holds a sleep-prevention assertion; `name` is what it called the assertion.
    case preventingSleep(name: String)

    public var text: String {
        switch self {
        case .building(let tool): return "Building (\(tool))"
        case .agentRunning: return "Claude Code is running tasks"
        case .playingAudio: return "Playing audio"
        case .preventingSleep: return "Keeping the Mac awake"
        }
    }

    /// The longer version, for a tooltip.
    public var detail: String {
        switch self {
        case .building(let tool): return "\(tool) is working in its process tree."
        case .agentRunning: return "A Claude Code session inside it has busy child processes."
        case .playingAudio: return "It's sending sound to an output device."
        case .preventingSleep(let name): return name.isEmpty ? "It's stopping the Mac from sleeping." : "It's stopping the Mac from sleeping (\(name))."
        }
    }
}

/// Decides, from one sample, which apps are busy. Pure, so it can be tested with made-up
/// process trees and `pmset` output.
public enum ActiveWork {
    public struct Limits: Sendable {
        /// A build tool counts as working at this CPU (% of one core) or above.
        public var buildCPU: Double = 10
        /// Claude Code counts as running tasks when a child of it is at this CPU or above.
        public var agentChildCPU: Double = 3
        public init() {}
    }

    /// Compilers, bundlers and build drivers. Matched against the process name.
    public static let buildTools: Set<String> = [
        "clang", "clang++", "cc", "c++", "gcc", "g++", "ld", "ld64", "ld-prime",
        "swift-frontend", "swiftc", "swift-build", "swift-driver", "swift", "xcodebuild",
        "XCBBuildService", "SWBBuildService", "ibtool", "ibtoold", "actool",
        "cargo", "rustc", "go", "make", "gmake", "ninja", "cmake", "bazel", "javac", "kotlinc",
        "node", "npm", "npx", "pnpm", "yarn", "bun", "deno", "tsc", "esbuild",
        "docker",
    ]
    /// Build clients whose work happens elsewhere (in Docker's VM), so they're busy just by
    /// running: `docker build` hands off to the buildx plugin, which sits idle while it waits.
    public static let remoteBuildTools: Set<String> = ["docker-buildx", "buildctl"]
    public static let agentNames: Set<String> = ["claude", "claude-code"]

    /// Busy apps by group id. Only Dock and menu bar apps are checked: everything else is
    /// never suggested anyway. `audioPIDs` is Core Audio's list; audio assertions add to it.
    public static func detect(groups: [AppGroup], processes: [ProcessSnapshot], assertions: [PowerAssertion],
                              audioPIDs: Set<Int32>, limits: Limits = Limits()) -> [String: ActiveWorkReason] {
        var children: [Int32: [Int32]] = [:]
        var byPID: [Int32: ProcessSnapshot] = [:]
        for p in processes {
            byPID[p.pid] = p
            if p.ppid != p.pid { children[p.ppid, default: []].append(p.pid) }
        }
        var audio = audioPIDs
        var sleep: [Int32: String] = [:]
        for a in assertions {
            if a.isAudioOutput { audio.insert(a.pid) } else if a.preventsSleep, sleep[a.pid] == nil { sleep[a.pid] = a.name }
        }

        var result: [String: ActiveWorkReason] = [:]
        for g in groups where g.kind == .app || g.kind == .menuBar {
            let tree = descendants(of: g.pids, children: children)
            if let r = reason(tree: tree, byPID: byPID, children: children, audio: audio, sleep: sleep, limits: limits) {
                result[g.id] = r
            }
        }
        return result
    }

    /// Checked in order of how sure a sign it is: a build, an agent at work, sound, a sleep assertion.
    static func reason(tree: [Int32], byPID: [Int32: ProcessSnapshot], children: [Int32: [Int32]],
                       audio: Set<Int32>, sleep: [Int32: String], limits: Limits) -> ActiveWorkReason? {
        let procs = tree.compactMap { byPID[$0] }
        if let remote = procs.first(where: { remoteBuildTools.contains($0.name) }) {
            return .building(tool: remote.name)
        }
        if let busiest = procs.filter({ buildTools.contains($0.name) && $0.cpuPercent >= limits.buildCPU })
            .max(by: { $0.cpuPercent < $1.cpuPercent }) {
            return .building(tool: busiest.name)
        }
        for agent in procs where isAgent(agent) {
            let below = descendants(of: [agent.pid], children: children).dropFirst()
            if below.contains(where: { (byPID[$0]?.cpuPercent ?? 0) >= limits.agentChildCPU }) { return .agentRunning }
        }
        if tree.contains(where: audio.contains) { return .playingAudio }
        if let pid = tree.first(where: { sleep[$0] != nil }) { return .preventingSleep(name: sleep[pid]!) }
        return nil
    }

    static func isAgent(_ p: ProcessSnapshot) -> Bool {
        agentNames.contains(p.name) || agentNames.contains((p.path as NSString).lastPathComponent)
    }

    /// The pids and everything started under them, roots first. Capped, in case of a cycle
    /// from a recycled pid.
    static func descendants(of roots: [Int32], children: [Int32: [Int32]]) -> [Int32] {
        var seen = Set<Int32>()
        var order: [Int32] = []
        var queue = roots.filter { $0 > 1 }
        var i = 0
        while i < queue.count, order.count < 4096 {
            let pid = queue[i]; i += 1
            guard seen.insert(pid).inserted else { continue }
            order.append(pid)
            queue.append(contentsOf: children[pid] ?? [])
        }
        return order
    }
}

/// Remembers busy apps for a little while: compilers come and go between samples, and a song
/// has gaps, so one quiet sample shouldn't make an app look idle. Used only on the sampling queue,
/// which is what makes it safe to hand there.
public final class ActiveWorkTracker: @unchecked Sendable {
    public var linger: TimeInterval
    public var limits: ActiveWork.Limits
    private var last: [String: (reason: ActiveWorkReason, at: Date)] = [:]

    public init(linger: TimeInterval = 120, limits: ActiveWork.Limits = .init()) {
        self.linger = linger; self.limits = limits
    }

    public func update(groups: [AppGroup], processes: [ProcessSnapshot], assertions: [PowerAssertion],
                       audioPIDs: Set<Int32>, now: Date) -> [String: ActiveWorkReason] {
        let found = ActiveWork.detect(groups: groups, processes: processes, assertions: assertions,
                                      audioPIDs: audioPIDs, limits: limits)
        for (id, r) in found { last[id] = (r, now) }
        let present = Set(groups.map(\.id))
        last = last.filter { present.contains($0.key) && now.timeIntervalSince($0.value.at) < linger }
        return last.mapValues(\.reason)
    }
}

/// One power assertion, as `pmset -g assertions` lists it under "Listed by owning process".
public struct PowerAssertion: Equatable, Sendable {
    public var ownerPID: Int32
    public var ownerName: String
    public var type: String
    public var name: String
    /// coreaudiod and WebKit hold assertions for another process and say which.
    public var createdForPID: Int32?
    public var resources: [String]

    public init(ownerPID: Int32, ownerName: String, type: String, name: String, createdForPID: Int32? = nil, resources: [String] = []) {
        self.ownerPID = ownerPID; self.ownerName = ownerName; self.type = type; self.name = name
        self.createdForPID = createdForPID; self.resources = resources
    }

    /// The process the assertion is really for.
    public var pid: Int32 { createdForPID ?? ownerPID }

    public static let sleepTypes: Set<String> = [
        "PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep", "PreventSystemSleep",
        "NoIdleSleepAssertion", "NoDisplaySleepAssertion",
    ]
    public var preventsSleep: Bool { Self.sleepTypes.contains(type) }
    public var isAudioOutput: Bool {
        resources.contains("audio-out") || (name.hasPrefix("com.apple.audio.") && name.contains(".context."))
    }
}

public enum PowerAssertions {
    /// Runs `pmset -g assertions`, giving up after two seconds so a stuck pmset can't stall sampling.
    public static func read(timeout: TimeInterval = 2) -> [PowerAssertion] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        var data = Data()
        do { try task.run() } catch { return [] }
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            task.terminate()
            return []
        }
        task.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Reads the "Listed by owning process" section. Each assertion is a line like
    /// `   pid 79712(Claude): [0x…] 46:51:34 NoIdleSleepAssertion named: "Electron"`,
    /// optionally followed by tab-indented lines such as `Created for PID: 1567.` and
    /// `Resources: audio-out BuiltInSpeakerDevice`.
    public static func parse(_ text: String) -> [PowerAssertion] {
        var result: [PowerAssertion] = []
        var inSection = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if raw.hasPrefix("Listed by owning process") { inSection = true; continue }
            guard inSection else { continue }
            guard raw.first == " " || raw.first == "\t" else { inSection = false; continue }
            let line = raw.drop { $0 == " " || $0 == "\t" }
            if line.hasPrefix("pid ") {
                if let a = owner(line) { result.append(a) }
            } else if !result.isEmpty, line.hasPrefix("Created for PID:") {
                let digits = line.dropFirst("Created for PID:".count).drop { $0 == " " }.prefix { $0.isNumber }
                result[result.count - 1].createdForPID = Int32(digits)
            } else if !result.isEmpty, line.hasPrefix("Resources:") {
                result[result.count - 1].resources = line.dropFirst("Resources:".count).split(separator: " ").map(String.init)
            }
        }
        return result
    }

    static func owner(_ line: Substring) -> PowerAssertion? {
        guard let open = line.firstIndex(of: "("),
              let pid = Int32(line[line.index(line.startIndex, offsetBy: 4)..<open]),
              let close = line.range(of: "): ["),
              let bracket = line[close.upperBound...].firstIndex(of: "]") else { return nil }
        let ownerName = String(line[line.index(after: open)..<close.lowerBound])
        // After the id: duration, type, then `named: "…"`.
        let fields = line[line.index(after: bracket)...].split(separator: " ", maxSplits: 2)
        guard fields.count >= 2 else { return nil }
        var name = ""
        if let named = line.range(of: "named: \"") {
            let tail = line[named.upperBound...]
            name = String(tail[..<(tail.lastIndex(of: "\"") ?? tail.endIndex)])
        }
        return PowerAssertion(ownerPID: pid, ownerName: ownerName, type: String(fields[1]), name: name)
    }
}
