import AppKit
import RamCleanCore
import SwiftUI

struct UsageBar: View {
    var title: String
    var value: Double // 0…1
    var detail: String
    var tint: Color
    /// Shown under the bar when it opens recommendations on click.
    var hint: String? = nil
    /// A warning on its own line under the detail (e.g. "Full in ~3 days at this rate"), in the bar's tint.
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text("\(Int((value * 100).rounded()))%").font(.title2.weight(.semibold)).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(tint.gradient).frame(width: max(6, geo.size.width * min(1, max(0, value))))
                }
            }
            .frame(height: 8)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let note {
                Text(note).font(.caption.weight(.medium)).foregroundStyle(tint).lineLimit(1)
            }
            if let hint {
                Label(hint, systemImage: "chevron.right.circle").font(.caption.weight(.medium)).foregroundStyle(tint)
                    .labelStyle(TrailingIconLabel())
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct AppIcon: View {
    var path: String?
    var size: CGFloat = 22
    /// Rows redraw on every check, so each app's icon is read from disk once, not each time.
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(_ path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }

    var body: some View {
        Group {
            if let path {
                Image(nsImage: Self.icon(path))
                    .resizable()
            } else {
                Image(systemName: "terminal").resizable().scaledToFit().padding(3).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

struct VerdictBadge: View {
    var assessment: Assessment

    var body: some View {
        let (text, color, symbol) = style
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .help(help)
    }

    private var style: (String, Color, String) {
        switch assessment.verdict {
        case .deadweight: return ("Deadweight \(Int(assessment.score * 100))%", .orange, "moon.zzz.fill")
        case .keep: return ("Keep · \(Int(assessment.score * 100))%", .green, "checkmark.circle.fill")
        case .protected(.busy(let work)): return (work.text, .blue, BusyBadge.symbol(work))
        case .protected(let reason): return (reason.text, .secondary, "lock.fill")
        }
    }

    private var help: String {
        if case .protected(.busy(let work)) = assessment.verdict { return "Not suggested while it's busy. \(work.detail)" }
        let source = assessment.usedModel ? "rules of thumb blended with your trained model" : "rules of thumb (model not trained yet)"
        return "Deadweight score \(Int(assessment.score * 100))% from \(source)."
    }
}

/// The small "Busy" tag on an app the active-work check is holding back from suggestions.
struct BusyBadge: View {
    var work: ActiveWorkReason

    var body: some View {
        Text("Busy")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.blue.opacity(0.15), in: Capsule())
            .foregroundStyle(.blue)
            .help("\(work.text). \(work.detail) RamClean won't suggest quitting it until it's done.")
            .accessibilityLabel("Busy: \(work.text)")
    }

    static func symbol(_ work: ActiveWorkReason) -> String {
        switch work {
        case .building: return "hammer.fill"
        case .agentRunning: return "terminal.fill"
        case .playingAudio: return "speaker.wave.2.fill"
        case .preventingSleep: return "cup.and.saucer.fill"
        }
    }
}

extension Assessment {
    /// What the active-work check found, when that's why it isn't suggested.
    var activeWork: ActiveWorkReason? {
        if case .protected(.busy(let work)) = verdict { return work }
        return nil
    }
}

struct TrailingIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.title; configuration.icon }
    }
}

func memoryTint(_ s: SystemSnapshot?) -> Color {
    guard let s else { return .accentColor }
    switch s.pressure {
    case .critical: return .red
    case .warning: return .orange
    case .normal: return s.memoryUsedFraction > 0.85 ? .orange : .accentColor
    }
}

/// Stands in for an app's Quit button while it's shutting down.
struct QuittingLabel: View {
    var body: some View {
        HStack(spacing: 5) {
            ProgressView().controlSize(.mini)
            Text("Quitting…").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Restarts an app that has swelled since it started: frees the growth, keeps the app.
struct RestartButton: View {
    @EnvironmentObject var model: AppModel
    var name: String
    var key: String
    var growth: MemoryGrowth.Growth

    var body: some View {
        Button("Restart") { model.restart(key: key) }
            .controlSize(.small)
            .accessibilityLabel("Restart \(name)")
            .help("Quit \(name) and open it again, freeing about \(Format.bytes(growth.freed)) it has built up. Not counted as deadweight.")
    }
}

enum GrowthText {
    static func short(_ g: MemoryGrowth.Growth) -> String {
        "grew \(Format.bytes(g.from)) → \(Format.bytes(g.to))"
    }
    static func long(_ g: MemoryGrowth.Growth) -> String {
        "Grew from \(Format.bytes(g.from)) to \(Format.bytes(g.to)) since \(g.since.formatted(date: .omitted, time: .shortened)); restarting frees about \(Format.bytes(g.freed))"
    }
}


/// A small "Free trial: 5 days left" / "Trial ended" link to the Licence settings. Hidden once
/// licensed, and in a development copy.
struct LicenceBadge: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.licence {
        case .licensed, .salesNotSetUp:
            EmptyView()
        default:
            Button { model.showLicenceSettings() } label: {
                Label(model.licence.title, systemImage: Self.symbol(model.licence)).font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Self.tint(model.licence))
            .help("Licence settings")
        }
    }

    static func symbol(_ s: LicenceState) -> String {
        switch s {
        case .trial: return "clock"
        case .licensed: return "checkmark.seal.fill"
        case .offlineGrace: return "wifi.slash"
        case .expired: return "lock.fill"
        case .salesNotSetUp: return "hammer"
        }
    }

    static func tint(_ s: LicenceState) -> Color {
        switch s {
        case .licensed: return .green
        case .expired: return .orange
        default: return .secondary
        }
    }
}
