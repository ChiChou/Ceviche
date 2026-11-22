import SwiftUI
import AppKit
import CevicheCore

extension View {
    /// Shows the XMP compatibility report as a notice in the top-trailing corner: what differs as a warning, and the
    /// import and export confirmations as plain notices. With `warnings` false only the confirmations show, for a
    /// report whose warnings `XMPWarningBanner` shows instead.
    func xmpReport(_ report: Binding<String?>, warnings: Bool = true) -> some View {
        overlay(alignment: .topTrailing) {
            Group {
                if let text = XMPCodec.compatibilityReport(report.wrappedValue ?? "") {
                    let confirmation = text == XMPCodec.importedNotice || text == XMPCodec.exportNotice
                    if confirmation || warnings {
                        NoticeToast(title: confirmation ? nil : L10n.tr("Some settings differ"), message: text, warning: !confirmation, notes: true) { report.wrappedValue = nil }
                            .transition(.opacity)
                    }
                }
            }
            .padding(.top, 52).padding(.trailing, 16)
            .animation(.easeOut(duration: 0.2), value: report.wrappedValue)
        }
    }

    /// The open photo's XMP warnings as a banner along the bottom of the photo: it waits for an answer without
    /// blocking the window, and leaves when the photo changes.
    func xmpWarningBanner(_ editor: EditorModel, strip: (() -> Void)?) -> some View {
        overlay(alignment: .bottom) {
            Group {
                if let text = XMPCodec.compatibilityReport(editor.xmpReport ?? ""), text != XMPCodec.importedNotice, text != XMPCodec.exportNotice,
                   !editor.peekingOriginal {
                    XMPWarningBanner(source: XMPCodec.sourceApplication(editor.xmpSourceData), report: text, strip: strip) { editor.xmpReport = nil }
                        .padding(.horizontal, 24).padding(.bottom, 20)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: editor.xmpReport)
        }
    }
}

/// What another application's sidecar asks for that Ceviche doesn't do, where it came from, and the way to stop
/// being told.
struct XMPWarningBanner: View {
    let source: String?
    let report: String
    let strip: (() -> Void)?
    let dismiss: () -> Void
    @State private var hovering = false
    @State private var copied = false

    private var title: String { source.map { L10n.tr("\($0) settings not applied") } ?? L10n.tr("Some XMP settings not applied") }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(title).font(.callout.weight(.semibold)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    // The title too, so a pasted report says which application wrote the sidecar.
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(title + "\n\n" + report, forType: .string)
                        copied = true
                    } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                        .help(L10n.tr("Copy Message")).accessibilityLabel(L10n.tr("Copy message"))
                    Button(action: dismiss) { Image(systemName: "xmark") }
                        .help(L10n.tr("Dismiss")).accessibilityLabel(L10n.tr("Dismiss"))
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary).controlSize(.small).opacity(hovering ? 1 : 0.5)
            }
            ScrollView { ReportNotes(report: report) }
                .frame(maxHeight: 200).fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 22)
            if let strip {
                // One line under a rule: where the settings are kept, and the way to stop being told.
                Rule().padding(.leading, 22).padding(.top, 4)
                HStack(alignment: .center, spacing: 12) {
                    Text(L10n.tr("Kept only for Export XMP."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(L10n.tr("Strip Unsupported Settings")) { strip(); dismiss() }
                        .buttonStyle(.secondaryAction).controlSize(.small)
                        .help(L10n.tr("Forget these settings so this warning stops. Your edits and the sidecar file are kept."))
                }
                .padding(.leading, 22)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: 460)
        // Opaque: over a bright photo a material takes on its color and washes out the text.
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .onHover { hovering = $0 }
        .onChange(of: report) { copied = false }
        .accessibilityElement(children: .contain)
    }
}

extension XMPCodec {
    /// Read each time, so a language switch in the app changes it too.
    static var importedNotice: String { L10n.tr("XMP settings imported.") }

    /// The application that wrote a packet, as its `xmp:CreatorTool` names it. Nil for Ceviche's own packets and unnamed ones.
    static func sourceApplication(_ data: Data?) -> String? {
        guard let data, let packet = try? XMPPacket(data: data),
              let tool = packet.value("CreatorTool", namespace: XMPPacket.xmp)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tool.isEmpty, tool != creatorTool else { return nil }
        return tool
    }
}
