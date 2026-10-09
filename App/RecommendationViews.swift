import AppKit
import RamCleanCore
import SwiftUI

/// Which usage bar was clicked.
enum UsagePanel: String, Identifiable {
    case memory, cpu, disk
    var id: String { rawValue }
}

/// Popover for the Memory or CPU bar: Dock apps ranked by that resource, with RamClean's verdict and why.
struct AppRecommendations: View {
    @EnvironmentObject var model: AppModel
    var panel: UsagePanel

    var body: some View {
        let apps = model.assessments.filter { $0.group.kind == .app }
            .sorted { panel == .cpu ? $0.cpuAverage > $1.cpuAverage : $0.group.memoryBytes > $1.group.memoryBytes }
            .prefix(12)
        let dead = apps.filter(\.isSuggestable)
        VStack(alignment: .leading, spacing: 0) {
            header(dead: Array(dead))
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(apps)) { a in
                        RecommendationRow(assessment: a, panel: panel)
                        Divider().opacity(0.5)
                    }
                }
            }
        }
        .frame(width: 540, height: 460)
    }

    private func header(dead: [Assessment]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(panel == .cpu ? "What's using CPU" : "What's using memory").font(.headline)
            if dead.isEmpty {
                Text("Nothing here looks like deadweight right now. The apps below are ranked by \(panel == .cpu ? "CPU" : "memory"), with why RamClean would keep them.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                let freed = dead.reduce(UInt64(0)) { $0 + $1.group.memoryBytes }
                Text("Recommended to quit: \(dead.map(\.group.name).joined(separator: ", ")). That frees about \(Format.bytes(freed)).")
                    .font(.callout)
            }
        }
        .padding(14)
    }
}

struct RecommendationRow: View {
    @EnvironmentObject var model: AppModel
    var assessment: Assessment
    var panel: UsagePanel

    var body: some View {
        let g = assessment.group
        let key = g.habitKey
        HStack(alignment: .top, spacing: 10) {
            AppIcon(path: g.bundlePath, size: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(g.name).font(.body.weight(.medium)).lineLimit(1)
                    Text(panel == .cpu ? "\(Int(assessment.cpuAverage.rounded()))% CPU" : Format.bytes(g.memoryBytes))
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                Text(assessment.reasons.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                verdict
                if case .protected = assessment.verdict {
                } else if model.awaitingForceQuit.contains(key) {
                    Button("Force Quit", role: .destructive) { model.forceQuit(key: key) }.controlSize(.small)
                        .accessibilityLabel("Force Quit \(g.name)")
                } else {
                    HStack(spacing: 6) {
                        Button("Quit") { model.quit(key: key, source: "recommendations") }.controlSize(.small)
                            .accessibilityLabel("Quit \(g.name)")
                        Button { model.keep(key: key, always: false, source: "recommendations") } label: { Image(systemName: "hand.thumbsup") }
                            .controlSize(.small).accessibilityLabel("Keep \(g.name)")
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    @ViewBuilder private var verdict: some View {
        switch assessment.verdict {
        case .deadweight: Label("Quit · \(Int(assessment.score * 100))%", systemImage: "moon.zzz.fill").foregroundStyle(.orange).font(.caption.weight(.semibold))
        case .keep: Label("Keep", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption.weight(.semibold))
        case .protected: Label("Protected", systemImage: "lock.fill").foregroundStyle(.secondary).font(.caption.weight(.semibold))
        }
    }
}

/// Popover for the Disk bar: rebuildable caches, large files and the Trash, each with Move to Trash.
struct DiskRecommendations: View {
    @EnvironmentObject var model: AppModel
    @State private var pending: DiskItem?
    @State private var pendingMove: (item: DiskItem, folder: URL, name: String)?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let report = model.diskReport {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(DiskItem.Kind.allCases, id: \.self) { kind in
                            let items = report.items(kind)
                            if !items.isEmpty {
                                Text(kind.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 14)
                                VStack(spacing: 0) {
                                    ForEach(items) { item in
                                        DiskRow(item: item, moving: model.movingPaths.contains(item.path),
                                                onTrash: { pending = item },
                                                onMove: { folder, name in pendingMove = (item, folder, name) })
                                        Divider().opacity(0.5)
                                    }
                                }
                            }
                        }
                        if report.items.isEmpty && model.diskScanStep == nil {
                            Text("Nothing big to clear: no large caches, large files or Trash found.")
                                .foregroundStyle(.secondary).padding(14)
                        }
                    }
                    .padding(.vertical, 12)
                }
            } else {
                Spacer()
            }
        }
        .frame(width: 560, height: 500)
        // Show the last results right away; refresh them in the background if they're over 30 minutes old.
        .onAppear {
            if let r = model.diskReport, Date().timeIntervalSince(r.scannedAt) < 30 * 60 { return }
            model.scanDisk()
        }
        .confirmationDialog(pending.map { "Move “\($0.name)” to the Trash?" } ?? "", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { item in
            Button("Move to Trash", role: .destructive) { error = model.moveToTrash(item) }
        } message: { item in
            Text("\(Format.bytes(UInt64(max(0, item.bytes ?? 0)))). \(item.caution ?? item.reason). You can put it back from the Trash until you empty it.")
        }
        .confirmationDialog(pendingMove.map { "Move “\($0.item.name)” to \($0.name)?" } ?? "", isPresented: Binding(
            get: { pendingMove != nil }, set: { if !$0 { pendingMove = nil } })) {
            Button("Move") {
                if let m = pendingMove { model.move(m.item, to: m.folder) { error = $0 } }
                pendingMove = nil
            }
        } message: {
            if let m = pendingMove {
                Text("\(Format.bytes(UInt64(max(0, m.item.bytes ?? 0)))) will be copied to \(m.folder.path), then removed from this Mac once the copy is complete.")
            }
        }
        .alert("That didn't work", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What you could clear").font(.headline)
                if let r = model.diskReport {
                    Text("About \(Format.bytes(UInt64(r.reclaimableBytes))) can go to the Trash. Space comes back when you empty it.")
                        .font(.callout)
                    Text("Scanned \(r.scannedAt.formatted(.relative(presentation: .named))). RamClean never empties the Trash or deletes anything itself.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let step = model.diskScanStep {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(model.diskReport == nil || model.diskReport!.scannedAt > Date().addingTimeInterval(-5)
                             ? "Scanning \(step)… results appear below as they're found"
                             : "Updating: checking \(step)…")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button("Rescan") { model.scanDisk() }.disabled(model.diskScanStep != nil)
        }
        .padding(14)
    }
}

struct DiskRow: View {
    var item: DiskItem
    var moving: Bool
    var onTrash: () -> Void
    var onMove: (URL, String) -> Void

    private var canMove: Bool { item.kind == .largeFile || item.kind == .oldDownload }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Text(item.bytes.map { Format.bytes(UInt64(max(0, $0))) } ?? "size unknown")
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    if item.suggestMove {
                        Text("Move off this Mac").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15), in: Capsule()).foregroundStyle(.blue)
                    }
                }
                Text(item.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let c = item.caution {
                    Label(c, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(item.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                if moving {
                    HStack(spacing: 4) { ProgressView().controlSize(.small); Text("Moving…").font(.caption) }
                } else {
                    if canMove { moveMenu }
                    if item.canTrash {
                        Button(item.kind == .unusedApp ? "Uninstall" : "Move to Trash", action: onTrash).controlSize(.small)
                            .accessibilityLabel("Move \(item.name) to Trash")
                    }
                }
                Button(item.kind == .trash ? "Open Trash" : "Show in Finder") {
                    let url = URL(fileURLWithPath: item.path)
                    if item.kind == .trash { NSWorkspace.shared.open(url) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                .controlSize(.small).buttonStyle(.link)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    /// Asks where to move it: any connected external drive, or a folder you pick.
    private var moveMenu: some View {
        Menu("Move to…") {
            let drives = AppModel.externalVolumes()
            if drives.isEmpty {
                Text("No external drive connected")
            } else {
                Section("External drives") {
                    ForEach(drives, id: \.url) { d in
                        Button("\(d.name) (\(Format.bytes(UInt64(max(0, d.free)))) free)") { onMove(d.url, d.name) }
                    }
                }
            }
            Divider()
            Button("Choose a folder…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.prompt = "Move Here"
                panel.message = "Choose where to move \(item.name)"
                if panel.runModal() == .OK, let url = panel.url { onMove(url, url.lastPathComponent) }
            }
        }
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel("Move \(item.name) to another drive or folder")
    }
}
