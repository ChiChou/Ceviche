import SwiftUI
import CevicheCore

/// Device-local work, never a photo: it cannot enter a photo selection or a photo command.
@MainActor
final class PendingOutput: ObservableObject, Identifiable {
    let id = UUID().uuidString
    let root: URL
    let source: CatalogAsset?
    let title: String
    let albumID: String?
    let journal: URL
    var scratchDirectory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Ceviche Job \(id)") }
    struct Record: Codable { var id: String; var output: URL? }
    private var generated: URL?
    @Published var progress: Double?
    @Published private(set) var aborted = false
    @Published private(set) var committing = false
    var cancel: (() -> Void)?
    var removeQueued: (() -> Void)?

    init(root: URL, source: CatalogAsset?, title: String, albumID: String?, journalDirectory: URL) throws {
        self.root = root; self.source = source; self.title = title; self.albumID = albumID
        journal = journalDirectory.appendingPathComponent(id).appendingPathExtension("json")
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        try recordGenerated(nil)
    }
    func recordGenerated(_ url: URL?) throws {
        generated = url
        try JSONEncoder().encode(Record(id: id, output: url)).write(to: journal, options: .atomic)
    }
    func cleanUp() {
        try? FileManager.default.removeItem(at: scratchDirectory)
        try? FileManager.default.removeItem(at: journal)
    }
    func abort() {
        guard !committing else { return }
        aborted = true
        if let cancel { cancel() } else { removeQueued?() }
    }
    func beginCommit() throws {
        try Task.checkCancellation()
        guard !aborted else { throw CancellationError() }
        committing = true
    }
}

extension CatalogModel {
    static func jobJournalDirectory(_ store: CatalogStore) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ceviche/Jobs/\(store.manifest.id)")
    }
    func recoverPendingOutputs(in store: CatalogStore) async {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.jobJournalDirectory(store), includingPropertiesForKeys: nil)) ?? []
        var interrupted = false
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            // A record that can't be read is from a crash mid-write: nothing can be recovered from it, so it goes.
            guard let record = try? JSONDecoder().decode(PendingOutput.Record.self, from: data), UUID(uuidString: record.id) != nil else {
                try? FileManager.default.removeItem(at: file); continue
            }
            guard !pendingOutputs.contains(where: { $0.id == record.id }) else { continue }
            // Only a photo surely not in the catalog has its output deleted; a catalog that can't be read now is
            // asked again next time.
            guard let found = try? await store.assets(ids: [record.id]) else { continue }
            if found.isEmpty {
                interrupted = true
                if let output = record.output, (try? output.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true {
                    try? FileManager.default.removeItem(at: output)
                }
            }
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("Ceviche Job \(record.id)"))
            try? FileManager.default.removeItem(at: file)
        }
        if interrupted { failure = Failure(L10n.tr("Jobs Interrupted"), L10n.tr("Unfinished jobs were interrupted. Start them again.")) }
    }
    func reserveOutput(source: CatalogAsset?, title: String, store: CatalogStore) throws -> PendingOutput {
        let output = try PendingOutput(root: store.root, source: source, title: title, albumID: filter.albumID, journalDirectory: Self.jobJournalDirectory(store))
        output.removeQueued = { [weak self, weak output] in
            guard let output else { return }; self?.finishOutput(output)
        }
        pendingOutputs.append(output)
        return output
    }
    func finishOutput(_ output: PendingOutput) {
        output.cancel = nil; output.removeQueued = nil
        output.cleanUp()
        pendingOutputs.removeAll { $0.id == output.id }
    }
}
