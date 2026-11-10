import SwiftUI

/// The drafted review for one PR: the approve call, each draft with its diff
/// line, and the only buttons in the app that write to GitHub.
struct ReviewView: View {
    @StateObject var model: ReviewModel
    @State private var confirming: GitHubClient.ReviewEvent?
    @FocusState private var keysFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 460)
        .focusable()
        .focusEffectDisabled()
        .focused($keysFocused)
        .onAppear { keysFocused = true }
        .onKeyPress(keys: ["j", "k", "x", "e"]) { press in
            guard model.editing == nil, !model.comments.isEmpty else { return .ignored }
            let current = model.comments[min(model.selection, model.comments.count - 1)]
            switch press.characters {
            case "j": model.selection = min(model.selection + 1, model.comments.count - 1)
            case "k": model.selection = max(model.selection - 1, 0)
            case "x": model.toggle(current)
            case "e": if !model.isPosted { model.editing = current.id }
            default: return .ignored
            }
            return .handled
        }
        .confirmationDialog(
            confirmTitle,
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible
        ) {
            Button(confirming == .approve ? "Approve" : "Post") {
                guard let event = confirming else { return }
                Task { await model.post(event) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This is posted to GitHub as you and cannot be unsent.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "#\(model.number)")
                    .foregroundStyle(.secondary)
                Text(model.result?.title ?? model.repo)
                    .lineLimit(2)
                Spacer()
                if let verdict = model.result?.verdict {
                    Text(verdict)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(verdictColor(verdict).opacity(0.16), in: Capsule())
                        .foregroundStyle(verdictColor(verdict))
                }
            }
            .font(.title3.weight(.semibold))

            if let result = model.result {
                Text(verbatim: "\(result.author) · reviewed \(result.reviewedAt.formatted(.relative(presentation: .named)))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(result.summary)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.headMoved {
                banner("The PR has new commits since this review. Re-run before posting.", color: .orange)
            }
            if let notice = model.notice {
                banner(notice, color: .red)
            }
        }
        .padding(16)
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func verdictColor(_ verdict: String) -> Color {
        switch verdict {
        case "can approve": return .green
        case "needs a real look": return .orange
        default: return .blue
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.result == nil || (model.isRunning && model.comments.isEmpty) {
            placeholder
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !model.topLevel.isEmpty { topLevelCard }
                        if model.comments.isEmpty {
                            Text("Nothing worth raising on this one.")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        }
                        ForEach(Array(model.comments.enumerated()), id: \.element.id) { index, comment in
                            card(comment, selected: index == model.selection)
                                .id(comment.id)
                                .onTapGesture { model.selection = index }
                        }
                    }
                    .padding(16)
                }
                .onChange(of: model.selection) { _, selection in
                    guard model.comments.indices.contains(selection) else { return }
                    withAnimation { proxy.scrollTo(model.comments[selection].id) }
                }
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            if model.isRunning {
                ProgressView()
                Text("Reviewing. This usually takes a few minutes.")
                    .foregroundStyle(.secondary)
            } else {
                Text(model.failed ? "The last review did not finish." : "Not reviewed yet.")
                    .foregroundStyle(.secondary)
                if model.failed {
                    Text(ReviewStore.logURL(repo: model.repo, number: model.number).path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                Button(model.failed ? "Try again" : "Start review") { model.run() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var topLevelCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $model.includeTopLevel)
                .labelsHidden()
                .disabled(model.isPosted)
            VStack(alignment: .leading, spacing: 6) {
                Text("Top-level comment")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let why = model.result?.topLevelWhy, !why.isEmpty { whyNote(why) }
                TextEditor(text: $model.topLevel)
                    .font(.body)
                    .frame(minHeight: 44)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .disabled(model.isPosted)
            }
        }
        .padding(10)
    }

    private func card(_ comment: ReviewDraft.Comment, selected: Bool) -> some View {
        let attachable = model.attachable(comment)

        return HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { model.included.contains(comment.id) },
                set: { _ in model.toggle(comment) }
            ))
            .labelsHidden()
            .disabled(model.isPosted || !attachable)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(verbatim: "\(comment.path):\(comment.line)")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    if comment.optional {
                        Text("optional").font(.caption).foregroundStyle(.tertiary)
                    }
                    if !attachable {
                        Text("line is not in the diff").font(.caption).foregroundStyle(.orange)
                    }
                }

                if let line = model.diffLines[comment.path]?[comment.line],
                   !line.dropFirst().allSatisfy(\.isWhitespace) {
                    Text(verbatim: line)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
                }

                if let why = comment.why, !why.isEmpty { whyNote(why) }

                if model.editing == comment.id {
                    TextEditor(text: Binding(
                        get: { model.text(for: comment) },
                        set: { model.edited[comment.id] = $0 }
                    ))
                    .font(.body)
                    .frame(minHeight: 70)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .onExitCommand {
                        model.editing = nil
                        keysFocused = true
                    }
                    Button("Done") {
                        model.editing = nil
                        keysFocused = true
                    }
                    .controlSize(.small)
                } else {
                    Text(model.text(for: comment))
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(model.included.contains(comment.id) ? 1 : 0.55)
                }
            }
        }
        .padding(10)
        .background(selected ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.18)))
        .contentShape(Rectangle())
    }

    /// Why the draft is worth raising. Hers to read, never part of what is posted.
    private func whyNote(_ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lightbulb")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
        .help("Why this is worth raising — for you only, never posted")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(footerStatus)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()

            Button("Open on GitHub") { model.openOnGitHub() }
            if model.result?.sessionId != nil {
                Button("Open chat") { model.openChat() }
            }
            if model.result != nil {
                Button(model.isRunning ? "Reviewing…" : "Re-run") { model.run() }
                    .disabled(model.isRunning)
            }
            if model.result != nil, !model.isPosted {
                Button("Approve and post") { confirming = .approve }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(!model.canPost)
                Button(postLabel) { confirming = .comment }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canPost || !hasSomethingToPost)
            }
        }
        .padding(12)
    }

    private var hasSomethingToPost: Bool {
        !model.selected.isEmpty || (model.includeTopLevel && !model.topLevel.isEmpty)
    }

    private var postLabel: String {
        model.isPosting ? "Posting…" : "Post \(whatWillBePosted)"
    }

    /// Names everything a post sends, so the count on the button is the count on GitHub.
    private var whatWillBePosted: String {
        let inline = model.selected.count
        let topLevel = model.includeTopLevel && !model.topLevel.isEmpty
        let inlineText = inline == 1 ? "1 inline comment" : "\(inline) inline comments"
        switch (inline, topLevel) {
        case (0, true): return "the top-level comment"
        case (_, true): return "\(inlineText) + top-level"
        case (0, false): return "no comments"
        default: return inlineText
        }
    }

    private var footerStatus: String {
        if let posted = model.result?.postedAt {
            let what = model.result?.postedEvent == "APPROVE" ? "Approved" : "Posted"
            return "\(what) \(posted.formatted(.relative(presentation: .named)))"
        }
        guard model.result != nil else { return "" }
        let topLevel = model.includeTopLevel && !model.topLevel.isEmpty ? " + top-level" : ""
        return "\(model.selected.count) of \(model.comments.count) selected\(topLevel) · j/k move, x toggle, e edit"
    }

    private var confirmTitle: String {
        switch confirming {
        case .approve: return "Approve #\(model.number) and post \(whatWillBePosted)?"
        default: return "Post \(whatWillBePosted) on #\(model.number)?"
        }
    }
}
