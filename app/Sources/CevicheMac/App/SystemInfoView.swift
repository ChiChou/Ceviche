import SwiftUI
import AppKit
import CevicheCore

struct SystemInfoView: View {
    static let windowID = "system-info"
    @State private var snapshot: SystemInfo?
    @Environment(\.dismiss) private var dismiss
    /// A snapshot given up front (previews, tests) is shown as it is; otherwise the window measures the Mac each time
    /// it opens.
    private let fixed: Bool

    init(snapshot: SystemInfo? = nil) { _snapshot = State(initialValue: snapshot); fixed = snapshot != nil }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                if let info = snapshot {
                    VStack(alignment: .leading, spacing: 16) {
                        Label(info.meetsRequirements ? L10n.tr("Core requirements met") : L10n.tr("Requirements not met"),
                              systemImage: info.meetsRequirements ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.headline).foregroundStyle(info.meetsRequirements ? Theme.pick : Theme.error)
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 9) {
                            row("Ceviche", info.appVersion)
                            row(L10n.tr("Mac"), info.model ?? L10n.tr("Not reported"))
                            row(L10n.tr("System"), info.systemVersion)
                            row("CPU", info.cpu ?? L10n.tr("Not reported"))
                            row(L10n.tr("Architecture"), info.architecture)
                            row(L10n.tr("CPU threads"), String(info.logicalCPUs))
                            row("RAM", SystemInfo.memory(info.ram))
                            Rule().gridCellUnsizedAxes(.horizontal)
                            row("GPU", info.gpu ?? L10n.tr("Not reported"))
                            row(L10n.tr("GPU memory"), info.memoryType)
                            row(L10n.tr("Metal budget"), SystemInfo.memory(info.gpuBudget))
                            row(L10n.tr("Max buffer"), SystemInfo.memory(info.maxBuffer))
                            row(L10n.tr("AI models found"), "\(info.modelsFound)/\(BundledModel.allCases.count)")
                        }
                        Text(L10n.tr("Metal budget is not free VRAM. Unified memory is shared with the CPU."))
                            .font(.caption).foregroundStyle(.secondary)
                        Rule()
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.tr("Diagnosis")).font(.headline)
                            ForEach(info.diagnosis, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
                            Text(L10n.tr("Capacity guidance only; memory needs depend on image size and tools."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
            }
            Rule()
            HStack {
                Button(L10n.tr("Copy Report")) {
                    guard let snapshot else { return }
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(snapshot.report, forType: .string)
                }.disabled(snapshot == nil)
                Spacer()
                Button(L10n.tr("OK")) { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(16)
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 560, idealHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { if !fixed { await refresh() } }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(verbatim: value).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    @MainActor private func refresh() async {
        snapshot = await Task.detached(priority: .userInitiated) { SystemInfo.capture() }.value
    }
}
