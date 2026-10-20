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

    var body: some View {
        Group {
            if let path {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
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
        case .protected(let reason): return (reason.text, .secondary, "lock.fill")
        }
    }

    private var help: String {
        let source = assessment.usedModel ? "rules of thumb blended with your trained model" : "rules of thumb (model not trained yet)"
        return "Deadweight score \(Int(assessment.score * 100))% from \(source)."
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

