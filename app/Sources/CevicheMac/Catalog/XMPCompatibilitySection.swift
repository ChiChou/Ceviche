import SwiftUI
import AppKit
import CevicheCore

/// The inspector's account of a photo's imported XMP: which application wrote it, each setting Ceviche doesn't
/// apply with the value it holds, the other notes, and Strip Unsupported Settings.
struct XMPCompatibilitySection: View {
    @ObservedObject var model: CatalogModel
    @ObservedObject var editor: EditorModel
    let asset: CatalogAsset
    let report: String
    @State private var packet: XMPPacket?
    @State private var copied = false

    private var notes: [String] {
        report.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    /// The names out of the "Unsupported:" note, which lists them as "A, B."; the other notes stay as written.
    private var parts: (unsupported: [String], other: [String]) {
        let prefix = L10n.tr("Unsupported: ").trimmingCharacters(in: .whitespaces)
        var unsupported: [String] = [], other: [String] = []
        for note in notes {
            if note.hasPrefix(prefix) {
                var list = note.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                if list.hasSuffix(".") { list.removeLast() }
                unsupported += list.components(separatedBy: ", ").filter { !$0.isEmpty }
            } else { other.append(note) }
        }
        return (unsupported, other)
    }
    private var source: String? {
        guard let tool = packet?.value("CreatorTool", namespace: XMPPacket.xmp)?.trimmingCharacters(in: .whitespacesAndNewlines), !tool.isEmpty else { return nil }
        return tool
    }

    var body: some View {
        let parts = parts
        InfoSection(L10n.tr("XMP Compatibility")) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copyText, forType: .string)
                copied = true
            } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(L10n.tr("Copy Message")).accessibilityLabel(L10n.tr("Copy message"))
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                MetadataRow.optional(L10n.tr("Written by"), source)
                if !parts.unsupported.isEmpty {
                    Text(L10n.tr("Not applied")).font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).padding(.top, source == nil ? 0 : 4)
                    ForEach(parts.unsupported, id: \.self) { name in
                        MetadataRow(title: name, value: value(of: name))
                    }
                }
                if !parts.other.isEmpty {
                    ForEach(Array(parts.other.enumerated()), id: \.offset) { _, note in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(Theme.warning)
                            Text(note).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(.top, parts.unsupported.isEmpty ? 0 : 4)
                }
            }
            .font(.caption)
            Button { Task { await model.stripUnsupportedXMP([asset], editor: editor) } } label: {
                Text(L10n.tr("Strip Unsupported Settings")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondaryAction).padding(.top, 4)
            .disabled(!model.canStripXMP([asset], editor: editor))
            .help(L10n.tr("Forget the imported XMP settings Ceviche doesn’t apply, so this warning stops. Edits are kept; the sidecar file isn’t changed."))
        }
        .task(id: [asset.id, report]) {
            copied = false
            let data = try? await model.store?.development(asset.id).xmpData
            packet = data.flatMap { try? XMPPacket(data: $0) }
        }
    }

    /// The value the sidecar holds for a setting; a structured one is only named as such.
    private func value(of name: String) -> String {
        if let value = packet?.value(name) { return value }
        return packet == nil ? "—" : L10n.tr("Structured value")
    }

    private var copyText: String {
        var lines: [String] = []
        if let source { lines.append(L10n.tr("Written by") + ": " + source) }
        let parts = parts
        if !parts.unsupported.isEmpty {
            lines.append(L10n.tr("Not applied") + ":")
            lines += parts.unsupported.map { "  \($0) = \(value(of: $0))" }
        }
        lines += parts.other
        return lines.joined(separator: "\n")
    }
}
