import AppKit
import RamCleanCore
import SwiftUI

struct UsageBar: View {
    var title: String
    var value: Double // 0…1
    var detail: String
    var tint: Color

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

func memoryTint(_ s: SystemSnapshot?) -> Color {
    guard let s else { return .accentColor }
    switch s.pressure {
    case .critical: return .red
    case .warning: return .orange
    case .normal: return s.memoryUsedFraction > 0.85 ? .orange : .accentColor
    }
}
