import XCTest
@testable import RamCleanCore

/// The active-work check, fed made-up process trees and `pmset -g assertions` output.
final class ActiveWorkTests: XCTestCase {
    // MARK: Fake process trees

    func proc(_ pid: Int32, _ ppid: Int32, _ name: String, path: String? = nil, cpu: Double = 0, tty: Bool = false) -> ProcessSnapshot {
        ProcessSnapshot(pid: pid, ppid: ppid, name: name, path: path ?? "/usr/bin/\(name)", footprintBytes: 50 << 20,
                        cpuPercent: cpu, hasTTY: tty)
    }
    func app(_ pid: Int32, _ name: String, _ bundleID: String, regular: Bool = true) -> RunningAppInfo {
        RunningAppInfo(pid: pid, bundleID: bundleID, name: name, bundlePath: "/Applications/\(name).app", isRegular: regular)
    }
    func appProc(_ pid: Int32, _ name: String, cpu: Double = 0) -> ProcessSnapshot {
        proc(pid, 1, name, path: "/Applications/\(name).app/Contents/MacOS/\(name)", cpu: cpu)
    }

    /// Groups the processes the way the app does, then runs the check. Keyed by app name.
    func busy(_ processes: [ProcessSnapshot], apps: [RunningAppInfo], pmset: String = "", audio: Set<Int32> = []) -> [String: ActiveWorkReason] {
        let groups = AppGrouper.group(processes, apps: apps)
        let found = ActiveWork.detect(groups: groups, processes: processes, assertions: PowerAssertions.parse(pmset), audioPIDs: audio)
        return Dictionary(uniqueKeysWithValues: groups.compactMap { g in found[g.id].map { (g.name, $0) } })
    }

    func testXcodeCompilingIsBusy() {
        let xcode = "/Applications/Xcode.app/Contents"
        let tree = [
            appProc(100, "Xcode", cpu: 5),
            proc(101, 100, "XCBBuildService", path: "\(xcode)/SharedFrameworks/XCBuild.framework/XCBBuildService", cpu: 4),
            proc(102, 101, "swift-frontend", path: "\(xcode)/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend", cpu: 180),
            proc(103, 101, "swift-frontend", path: "\(xcode)/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend", cpu: 90),
        ]
        XCTAssertEqual(busy(tree, apps: [app(100, "Xcode", "com.apple.dt.Xcode")]), ["Xcode": .building(tool: "swift-frontend")])
    }

    func testIdleBuildToolsDontCount() {
        // A dev server or MCP server sitting idle is not a build.
        let tree = [appProc(200, "Code"), proc(201, 200, "node", cpu: 1.5), proc(202, 200, "tsc", cpu: 0)]
        XCTAssertEqual(busy(tree, apps: [app(200, "Code", "com.microsoft.VSCode")]), [:])
    }

    func testBuildInTerminalSessionCountsForTheHostApp() {
        // Code → zsh → cargo → rustc: the compiler is several levels down and in its own group.
        let tree = [
            appProc(300, "Code"), proc(301, 300, "zsh", tty: true), proc(302, 301, "cargo", cpu: 2, tty: true),
            proc(303, 302, "rustc", cpu: 340, tty: true),
        ]
        XCTAssertEqual(busy(tree, apps: [app(300, "Code", "com.microsoft.VSCode")])["Code"], .building(tool: "rustc"))
    }

    func testDockerBuildIsBusyEvenWhileTheClientIsIdle() {
        // The work happens in Docker's VM; the buildx plugin just waits.
        let tree = [appProc(400, "iTerm"), proc(401, 400, "zsh", tty: true), proc(402, 401, "docker", tty: true),
                    proc(403, 402, "docker-buildx", path: "/usr/local/lib/docker/cli-plugins/docker-buildx", tty: true)]
        XCTAssertEqual(busy(tree, apps: [app(400, "iTerm", "com.googlecode.iterm2")])["iTerm"], .building(tool: "docker-buildx"))
    }

    func testClaudeCodeWithActiveChildrenIsBusy() {
        let claude = "/Users/me/Library/Application Support/Claude/claude-code/2.1.304/x/claude.app/Contents/MacOS/claude"
        let tree = [
            appProc(500, "Claude"), proc(501, 500, "disclaimer"), proc(502, 501, "claude", path: claude, cpu: 1),
            proc(503, 502, "node", cpu: 0.2),       // an idle MCP server
            proc(504, 502, "bash", cpu: 0), proc(505, 504, "pytest", path: "/opt/homebrew/bin/pytest", cpu: 45),
        ]
        XCTAssertEqual(busy(tree, apps: [app(500, "Claude", "com.anthropic.claudefordesktop")]), ["Claude": .agentRunning])
    }

    func testClaudeCodeWithOnlyIdleChildrenIsNotBusy() {
        let tree = [appProc(500, "Claude"), proc(502, 500, "claude", cpu: 0.5), proc(503, 502, "node", cpu: 0.2)]
        XCTAssertEqual(busy(tree, apps: [app(500, "Claude", "com.anthropic.claudefordesktop")]), [:])
    }

    func testClaudeCodeFoundByPathWhenTheNameDiffers() {
        let tree = [appProc(500, "Ghostty"), proc(501, 500, "2.1.304", path: "/Users/me/.local/share/claude/versions/claude-code", cpu: 2),
                    proc(502, 501, "git", cpu: 12)]
        XCTAssertEqual(busy(tree, apps: [app(500, "Ghostty", "com.mitchellh.ghostty")])["Ghostty"], .agentRunning)
    }

    func testOnlyAppsAreChecked() {
        // A busy compiler with no app above it is already a command-line group that's never suggested.
        let tree = [proc(600, 1, "zsh", tty: true), proc(601, 600, "clang", cpu: 99, tty: true)]
        XCTAssertEqual(busy(tree, apps: []), [:])
    }

    func testBuildOutranksAudio() {
        let tree = [appProc(700, "Code"), proc(701, 700, "esbuild", cpu: 60)]
        XCTAssertEqual(busy(tree, apps: [app(700, "Code", "com.microsoft.VSCode")], audio: [700])["Code"], .building(tool: "esbuild"))
    }

    // MARK: Fake pmset output

    /// Trimmed from a real Mac, plus audio and WebKit entries in the format coreaudiod and WebKit use.
    let pmset = """
    2026-10-23 11:52:01 -0700
    Assertion status system-wide:
       BackgroundTask                 0
       UserIsActive                   1
       PreventUserIdleDisplaySleep    1
       PreventUserIdleSystemSleep     1
    Listed by owning process:
       pid 143(powerd): [0x000371b5001084f7] 00:00:18 InternalPreventDisplaySleep named: "com.apple.powermanagement.delayDisplayOff"
    \tTimeout will fire in 282 secs Action=TimeoutActionTurnOff
       pid 79712(Claude): [0x0000e1e400018e79] 46:51:34 NoIdleSleepAssertion named: "Electron"
       pid 158(mds): [0x000372eb000b9fd1] 00:08:13 BackgroundTask named: "com.apple.metadata.mds.power"
       pid 432(coreaudiod): [0x0000a2b100018fb1] 00:00:13 PreventUserIdleSystemSleep named: "com.apple.audio.BuiltInSpeakerDevice.context.preventuseridlesleep"
    \tCreated for PID: 1567.
    \tResources: audio-out BuiltInSpeakerDevice
       pid 880(WebKit (GPU)): [0x0000a2b100018fc2] 00:02:40 PreventUserIdleDisplaySleep named: "WebKit Media Playback"
    \tCreated for PID: 900.
       pid 263(WindowServer): [0x0000001e000980d3] 00:00:00 UserIsActive named: "com.apple.iohideventsystem.queue.tickle"
    Kernel Assertions: 0x104=USB,MAGICWAKE
       id=507  level=255 0x4=USB creat= description=com.apple.usb.externaldevice.00100000 owner=USB3.1 Hub
    Idle sleep preventers: IODisplayWrangler
    """

    func testParsesPmsetAssertions() {
        let all = PowerAssertions.parse(pmset)
        XCTAssertEqual(all.map(\.ownerName), ["powerd", "Claude", "mds", "coreaudiod", "WebKit (GPU)", "WindowServer"])
        XCTAssertEqual(all[1], PowerAssertion(ownerPID: 79712, ownerName: "Claude", type: "NoIdleSleepAssertion", name: "Electron"))
        XCTAssertEqual(all[3].createdForPID, 1567)
        XCTAssertEqual(all[3].resources, ["audio-out", "BuiltInSpeakerDevice"])
        XCTAssertTrue(all[3].isAudioOutput)
        XCTAssertEqual(all[4].pid, 900)
        XCTAssertEqual(all.filter(\.preventsSleep).map(\.ownerName), ["Claude", "coreaudiod", "WebKit (GPU)"])
        XCTAssertEqual(PowerAssertions.parse(""), [])
        XCTAssertEqual(PowerAssertions.parse("Listed by owning process:\n   pid garbage\n"), [])
    }

    func testAudioAssertionMarksTheAppItsFor() {
        // coreaudiod holds the assertion, on behalf of a Spotify helper.
        let tree = [appProc(1500, "Spotify"), proc(1567, 1500, "Spotify Helper", path: "/Applications/Spotify.app/Contents/Frameworks/Spotify Helper.app/Contents/MacOS/Spotify Helper")]
        XCTAssertEqual(busy(tree, apps: [app(1500, "Spotify", "com.spotify.client")], pmset: pmset), ["Spotify": .playingAudio])
    }

    func testCoreAudioPIDsAlsoCount() {
        XCTAssertEqual(busy([appProc(1500, "Music")], apps: [app(1500, "Music", "com.apple.Music")], audio: [1500]), ["Music": .playingAudio])
    }

    func testSleepAssertionMarksTheApp() {
        let found = busy([appProc(79712, "Claude"), appProc(900, "Safari"), appProc(263, "Notes")],
                         apps: [app(79712, "Claude", "com.anthropic.claudefordesktop"), app(900, "Safari", "com.apple.Safari"),
                                app(263, "Notes", "com.apple.Notes")],
                         pmset: pmset)
        XCTAssertEqual(found["Claude"], .preventingSleep(name: "Electron"))
        XCTAssertEqual(found["Safari"], .preventingSleep(name: "WebKit Media Playback"))
        XCTAssertNil(found["Notes"], "UserIsActive isn't a sleep assertion")
    }

    // MARK: Linger and the verdict

    func testBusyLingersBetweenCompileSteps() {
        let tracker = ActiveWorkTracker(linger: 120)
        let apps = [app(100, "Xcode", "com.apple.dt.Xcode")]
        let building = [appProc(100, "Xcode"), proc(101, 100, "clang", cpu: 95)]
        let between = [appProc(100, "Xcode")]
        let t0 = Date()
        func update(_ p: [ProcessSnapshot], _ at: TimeInterval, apps: [RunningAppInfo]) -> [String: ActiveWorkReason] {
            tracker.update(groups: AppGrouper.group(p, apps: apps), processes: p, assertions: [], audioPIDs: [], now: t0 + at)
        }
        let id = "/Applications/Xcode.app"
        XCTAssertEqual(update(building, 0, apps: apps)[id], .building(tool: "clang"))
        XCTAssertEqual(update(between, 60, apps: apps)[id], .building(tool: "clang"))
        XCTAssertNil(update(between, 121, apps: apps)[id])
        XCTAssertEqual(update(building, 130, apps: apps)[id], .building(tool: "clang"))
        XCTAssertEqual(update([], 140, apps: []), [:], "a quit app is forgotten")
    }

    func testBusyAppIsProtectedAndNeverSuggested() {
        let g = AppGroup(id: "/Applications/Xcode.app", kind: .app, name: "Xcode", bundleID: "com.apple.dt.Xcode",
                         bundlePath: "/Applications/Xcode.app", mainPID: 1, pids: [1], memoryBytes: 8 << 30,
                         cpuPercent: 0, hostedCommands: [], hostedCPUPercent: 0)
        let idle = HabitStats(minutesSinceActive: 600, foregroundMinutesToday: 0, avgDailyMinutes14d: 0, daysUsed14d: 0,
                              launches7d: 0, timesKept: 0, timesQuit: 5, regrets: 0)
        func assess(_ work: [String: ActiveWorkReason]) -> Assessment {
            Assessor(prefs: Preferences(), frontmostKey: nil, selfBundleID: nil, audioPIDs: [], activeWork: work,
                     cpuAverages: [:], now: Date())
                .assess([g], stats: { _ in idle }, score: { _ in (0.95, true) })[0]
        }
        XCTAssertEqual(assess([:]).verdict, .deadweight)
        let held = assess([g.id: .building(tool: "swift-frontend")])
        XCTAssertEqual(held.verdict, .protected(.busy(.building(tool: "swift-frontend"))))
        XCTAssertFalse(held.isSuggestable)
        XCTAssertEqual(held.reasons.first, "Building (swift-frontend)")
        let tight = SystemSnapshot(totalMemory: 16 << 30, usedMemory: 15 << 30)
        XCTAssertNil(SuggestionPolicy(prefs: Preferences()).pick(from: [held], system: tight, lastNotified: [:],
                                                                   lastAnyNotification: nil, now: Date()))
        XCTAssertNil(AlertRecommender.memory(tight, [held]).action, "alerts don't offer to quit it either")
    }

    func testBusyBeatsFrontmost() {
        let g = AppGroup(id: "a", kind: .app, name: "A", bundleID: "a", bundlePath: nil, mainPID: 1, pids: [1],
                         memoryBytes: 1 << 30, cpuPercent: 0, hostedCommands: [], hostedCPUPercent: 0)
        let c = ProtectionContext(prefs: Preferences(), frontmostKey: "a", selfBundleID: nil, activeWork: .agentRunning,
                                  cpuAverage: 0, minutesSinceActive: 0)
        XCTAssertEqual(ProtectionRules.reason(for: g, c), .busy(.agentRunning))
    }
}
