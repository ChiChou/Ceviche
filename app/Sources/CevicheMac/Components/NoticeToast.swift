import CevicheCore
import SwiftUI
import AppKit

extension View {
    /// Every transient message in one place, centred above the status bar: errors as dismissible notices instead of a
    /// modal alert, stacked over the brief confirmation of finished work ("Moved to Trash"), so the two never overlap.
    func toasts(errors: Binding<String?>..., notice: Binding<String?>) -> some View {
        overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                ForEach(errors.indices, id: \.self) { index in
                    if let message = errors[index].wrappedValue {
                        NoticeToast(message: message) { errors[index].wrappedValue = nil }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                if let message = notice.wrappedValue {
                    SuccessToast(message: message) { notice.wrappedValue = nil }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 48)
            .animation(.snappy(duration: 0.25), value: errors.map(\.wrappedValue) + [notice.wrappedValue])
        }
    }
}

/// A small pill for finished work: nothing to read twice or act on, so it has no buttons and leaves on its own.
private struct SuccessToast: View {
    let message: String
    let dismiss: () -> Void
    var body: some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .labelStyle(SuccessLabelStyle())
            .font(.callout.weight(.medium)).lineLimit(1)
            .padding(.leading, 12).padding(.trailing, 16).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
            .onTapGesture(perform: dismiss)
            .task(id: message) {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { dismiss() }
            }
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isStaticText)
    }
}

private struct SuccessLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) { configuration.icon.foregroundStyle(.green); configuration.title }
    }
}

struct NoticeToast: View {
    var title: String? = nil
    let message: String
    var warning = true
    /// Shows `message` as `ReportNotes`, one note per paragraph, instead of as one block of text.
    var notes = false
    var seconds: Double? = nil
    let dismiss: () -> Void
    @State private var hovering = false
    @State private var copied = false

    private var duration: Duration { .seconds(seconds ?? min(15, 6 + Double(message.count) / 20)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(warning ? Color.yellow : Color.blue).font(.callout)
                Text(title ?? (warning ? L10n.tr("Error") : L10n.tr("Notice"))).font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message, forType: .string)
                        copied = true
                    } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                        .help(L10n.tr("Copy Message")).accessibilityLabel(L10n.tr("Copy message"))
                    Button(action: dismiss) { Image(systemName: "xmark") }
                        .help(L10n.tr("Dismiss")).accessibilityLabel(L10n.tr("Dismiss"))
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary).controlSize(.small)
                .opacity(hovering ? 1 : 0.5)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            // As tall as the message, up to 200 points, then scrolling; a flexible frame alone would take the full
            // 200 points and center a short message in it.
            ScrollView { content }
                .frame(maxHeight: 200).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.bottom, 10)
        }
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        .onHover { hovering = $0 }
        .task(id: [message, hovering ? "hover" : ""]) {
            guard !hovering else { return }
            try? await Task.sleep(for: duration)
            if !Task.isCancelled { dismiss() }
        }
        .onChange(of: message) { copied = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("\(title ?? (warning ? L10n.key("Error") : L10n.key("Notice"))): \(message)"))
    }

    @ViewBuilder private var content: some View {
        if notes { ReportNotes(report: message) } else {
            Text(message).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Compatibility notes, one per paragraph of a report, as a compact list.
struct ReportNotes: View {
    let report: String
    private var notes: [String] {
        report.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if notes.count > 1 { Text(verbatim: "•").foregroundStyle(.tertiary) }
                    Text(note).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
