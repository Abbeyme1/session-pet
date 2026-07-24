import SwiftUI

let stateLabel: [String: String] = ["idle": "Idle", "working": "Working", "waiting": "Waiting", "error": "Error"]

struct RowView: View {
    @ObservedObject var store: SessionStore
    let session: SessionStatus
    @Binding var draggingId: String?
    @State private var freeTextInput: String = ""
    @State private var lastOptionClickAt: Date? = nil
    @State private var isRenaming = false
    @State private var renameText = ""
    @FocusState private var isNameFieldFocused: Bool
    @State private var isHoveringHandle = false
    @State private var isHoveringRow = false
    @State private var consumedDragSteps = 0

    var isBeingDragged: Bool { draggingId == session.session_id }
    // Approximate collapsed-row height (handle icon height 20 + 5pt vertical
    // padding top/bottom). Doesn't need to be exact — it's just the unit
    // size for "how many rows did this drag cross," and imprecision only
    // means slightly more/less travel per step, not incorrect behavior.
    private let rowHeightUnit: CGFloat = 34

    var isExpanded: Bool { store.expandedId == session.session_id }
    var isPinned: Bool { store.pinnedIds.contains(session.session_id) }
    var isTextEntry: Bool { store.textEntryFor == session.session_id }
    var subagents: [SessionStatus] { store.subagentsBySession[session.session_id] ?? [] }
    var displayName: String { store.customNames[session.session_id] ?? session.name }

    /// Blocks a rapid double/triple click on the same option before the
    /// pane's had a chance to move on — this is what "444" (a real click on
    /// "Chat about this" landing 3 times) was: no feedback that the first
    /// tap registered, so more taps seemed reasonable. Refreshes on its own
    /// since `store.sessions` already re-renders this view every second.
    var isCoolingDown: Bool {
        guard let last = lastOptionClickAt else { return false }
        return Date().timeIntervalSince(last) < 1.2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                // Dedicated drag handle — dragging used to start from
                // anywhere on the row, which felt accidental/buggy since it
                // fought with taps elsewhere. A plain DragGesture instead of
                // onDrag/onDrop — the system drag-and-drop machinery
                // (NSItemProvider, async session setup) is what made the
                // old version feel laggy; this tracks the cursor 1:1 and
                // mutates the order directly, no round trip.
                Image(systemName: "circle.grid.2x2.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .frame(width: 10, height: 20)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        isHoveringHandle = hovering
                        if hovering { NSCursor.openHand.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 2, coordinateSpace: .global)
                            .onChanged { value in
                                if draggingId != session.session_id {
                                    draggingId = session.session_id
                                    consumedDragSteps = 0
                                }
                                let steps = Int((value.translation.height / rowHeightUnit).rounded())
                                if steps != consumedDragSteps {
                                    store.moveSessionBy(id: session.session_id, steps: steps - consumedDragSteps)
                                    consumedDragSteps = steps
                                }
                            }
                            .onEnded { _ in
                                draggingId = nil
                                consumedDragSteps = 0
                            }
                    )

                AnimatedPetIcon(state: session.state, size: 26, idleSince: store.idleSince(for: session))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if isRenaming {
                            TextField("Name", text: $renameText, onCommit: {
                                store.rename(session.session_id, to: renameText)
                                isRenaming = false
                            })
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .focused($isNameFieldFocused)
                            .onExitCommand { isRenaming = false } // Esc cancels, discards edit
                        } else {
                            Text(displayName).font(.system(size: 12, weight: .semibold))
                        }
                        Text(stateLabel[session.state] ?? session.state)
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(stateColor(session.state).opacity(0.18))
                            .foregroundColor(stateTextColor(session.state))
                            .clipShape(Capsule())

                        // Inline with name/chip — no extra line just for
                        // this, per feedback. Always visible (not behind a
                        // click, per earlier feedback).
                        if session.state == "working" {
                            PacmanLoader(width: 28, height: 8)
                            if let elapsed = store.elapsed(for: session) {
                                Text(elapsed)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    Text(session.cwd)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer()

                if isRenaming {
                    Button(action: { isRenaming = false }) {
                        Image(systemName: "xmark").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel")

                    Button(action: {
                        store.rename(session.session_id, to: renameText)
                        isRenaming = false
                    }) {
                        Image(systemName: "checkmark").foregroundColor(stateColor("working"))
                    }
                    .buttonStyle(.plain)
                    .help("Save name")
                } else {
                    // Hidden until hover — a rename button visible at all
                    // times read as "too much on the face" per feedback;
                    // opacity (not `if`) keeps its layout slot reserved so
                    // neighboring icons don't jump when it appears.
                    Button(action: {
                        renameText = displayName
                        isRenaming = true
                        isNameFieldFocused = true
                    }) {
                        Image(systemName: "square.and.pencil").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Rename")
                    .opacity(isHoveringRow ? 1 : 0)
                    .allowsHitTesting(isHoveringRow)
                }

                Button(action: { store.togglePin(session.session_id) }) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .foregroundColor(isPinned ? stateColor("waiting") : .secondary)
                }
                .buttonStyle(.plain)

                if session.tmux_pane != nil {
                    Button(action: { Task { await store.focusPane(session.tmux_pane!) } }) {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .buttonStyle(.plain)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { store.toggleExpanded(session.session_id) }
            .onHover { isHoveringRow = $0 }
            .padding(.vertical, 5)

            if !subagents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(subagents) { sub in
                        SubagentRow(store: store, sub: sub)
                    }
                }
                .padding(.leading, 28)
                .padding(.bottom, 6)
            }

            if isExpanded && session.state != "working" {
                detail.padding(.bottom, 8).padding(.leading, 28)
            }
        }
        .padding(.horizontal, Theme.spacingS)
        .padding(.vertical, Theme.spacingXS)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusM)
                .fill(isBeingDragged ? Color.primary.opacity(0.07) : Color.primary.opacity(isHoveringRow ? 0.045 : 0.028))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusM)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        )
        .scaleEffect(isBeingDragged ? 1.02 : 1)
        .shadow(color: .black.opacity(isBeingDragged ? 0.25 : 0), radius: 6, y: 2)
        .animation(Theme.animationFast, value: isBeingDragged)
    }

    private func send(_ pane: String) {
        let text = freeTextInput.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        Task { await store.sendFreeText(paneId: pane, text: text) }
        freeTextInput = ""
    }

    @ViewBuilder
    var detail: some View {
        switch session.state {
        case "waiting" where session.tool == "AskUserQuestion":
            if let pane = session.tmux_pane, isTextEntry {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TYPE YOUR ANSWER").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                    HStack(spacing: 6) {
                        TextField("Message", text: $freeTextInput)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { send(pane) }
                        Button("Send") { send(pane) }
                            .buttonStyle(.borderedProminent)
                            .tint(stateColor("working"))
                            .disabled(freeTextInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Button("← Back") {
                        freeTextInput = ""
                        Task { await store.cancelFreeText(paneId: pane) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                }
            } else if let pane = session.tmux_pane, let parsed = store.parsedPrompts[session.session_id] {
                VStack(alignment: .leading, spacing: 8) {
                    Text(parsed.question)
                        .font(.system(size: 11, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(parsed.options, id: \.number) { option in
                            Button(action: {
                                guard !isCoolingDown else { return }
                                lastOptionClickAt = Date()
                                if SessionStore.isFreeTextOption(option.label) {
                                    Task { await store.beginFreeText(paneId: pane, sessionId: session.session_id, number: option.number) }
                                } else {
                                    Task { await store.selectOption(pane, number: option.number) }
                                }
                            }) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                        .font(.system(size: 11, weight: .semibold))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .foregroundColor(stateTextColor("waiting"))
                                    if let description = option.description {
                                        Text(description)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, option.description != nil ? 8 : 5)
                                .background(stateColor("waiting").opacity(0.12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(stateColor("waiting").opacity(0.4), lineWidth: 1)
                                )
                                .cornerRadius(6)
                            }
                            // .bordered here previously clipped multi-line
                            // labels to one line regardless of fixedSize —
                            // a known macOS 13 SwiftUI quirk where bordered
                            // button styles don't size around multi-line
                            // content. .plain + manual chrome above sidesteps
                            // it entirely, same pattern as the state chips.
                            .buttonStyle(.plain)
                            .disabled(isCoolingDown)
                        }
                    }
                }
            } else {
                Text("Question prompt — answer in the terminal.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
        case "waiting":
            let toolIsSafe = SAFE_APPROVE_TOOLS.contains(session.tool ?? "")
            let diff = store.diffPreview(for: session)
            VStack(alignment: .leading, spacing: 6) {
                Text("WANTS TO RUN").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                HStack(spacing: 6) {
                    Text(session.tool ?? "?")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(stateColor("waiting").opacity(0.18))
                        .foregroundColor(stateTextColor("waiting"))
                        .clipShape(Capsule())
                }
                if let diff {
                    if let path = session.tool_input?.file_path ?? session.tool_input?.notebook_path {
                        Text(path)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    DiffView(preview: diff)
                } else if let detail = session.toolDetail {
                    Text(detail)
                        .font(.system(size: 10, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(6)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(6)
                }
                if toolIsSafe, let pane = session.tmux_pane {
                    HStack(spacing: 8) {
                        Button("Approve") { Task { await store.sendApprove(pane) } }
                            .buttonStyle(.borderedProminent).tint(stateColor("working"))
                        Button("Deny") { Task { await store.sendDeny(pane) } }
                            .buttonStyle(.bordered).tint(stateColor("error"))
                    }
                } else {
                    Text("\(session.tool ?? "This")-style prompt isn't a simple yes/no — answer in the terminal.")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
        case "error":
            VStack(alignment: .leading, spacing: 6) {
                Text("ERROR").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                Text("\(session.tool ?? "A tool") failed" + (session.toolDetail.map { ": \($0)" } ?? "."))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(stateTextColor("error"))
            }
        default:
            Text("No activity right now.").font(.system(size: 10)).foregroundColor(.secondary)
        }
    }
}

/// One Task-tool subagent spawned by a parent session. Own row, own
/// click-to-expand — subagents share the parent's session_id (verified
/// live), so they're carried as a separate list keyed by parent id rather
/// than as regular top-level sessions (see SessionStore.liveSubagents).
private struct SubagentRow: View {
    @ObservedObject var store: SessionStore
    let sub: SessionStatus
    var isExpanded: Bool { store.expandedSubagentId == sub.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(stateColor(sub.state)).frame(width: 6, height: 6)
                Text(sub.agent_type ?? "subagent")
                    .font(.system(size: 10, weight: .semibold))
                Text(stateLabel[sub.state] ?? sub.state)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(stateColor(sub.state))
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { store.expandedSubagentId = isExpanded ? nil : sub.id }

            if isExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    if let tool = sub.tool {
                        Text(tool).font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
                    }
                    if let detail = sub.toolDetail {
                        Text(detail)
                            .font(.system(size: 9, design: .monospaced))
                            .padding(5)
                            .background(Color.primary.opacity(0.06))
                            .cornerRadius(5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 12)
            }
        }
    }
}
