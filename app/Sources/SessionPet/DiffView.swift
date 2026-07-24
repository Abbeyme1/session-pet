import SwiftUI

/// A single rendered line of a condensed diff — real content, never
/// fabricated: Edit diffs old_string/new_string directly; Write diffs the
/// file's current on-disk content (still the pre-edit version, since this
/// renders during the "waiting" approval state, before the tool runs)
/// against the incoming content. NotebookEdit has no accessible "old" cell
/// source without parsing notebook JSON, so it renders as all-added.
struct DiffLine: Identifiable {
    enum Kind { case same, added, removed, contextGap }
    let id = UUID()
    let kind: Kind
    let text: String
}

struct DiffPreview {
    let lines: [DiffLine]
    let omittedCount: Int
}

/// Renders condensed to changed lines (+/- 1 line of context) and capped at
/// a fixed line count — deliberately not scrollable. A ScrollView here
/// previously broke the dropdown's rendering entirely (see DESIGN.md) and
/// that's still unresolved; capping length keeps this safe without reviving
/// that bug. Nothing is silently hidden without saying so — an omitted
/// count always renders when lines were cut.
struct DiffView: View {
    let preview: DiffPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(preview.lines) { line in lineView(line) }
            if preview.omittedCount > 0 {
                Text("… \(preview.omittedCount) more line\(preview.omittedCount == 1 ? "" : "s") changed")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(6)
        .background(Color.primary.opacity(0.06))
        .cornerRadius(6)
    }

    @ViewBuilder
    private func lineView(_ line: DiffLine) -> some View {
        switch line.kind {
        case .contextGap:
            Text("⋯")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
        case .same:
            Text("  " + line.text)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .added:
            Text("+ " + line.text)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .removed:
            Text("- " + line.text)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.red)
                .strikethrough()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
