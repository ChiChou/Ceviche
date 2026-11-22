import Foundation

// A tiny app-bundle test host; the production service is launched by XPC, not exec'd.
@objc(CevicheIndexServiceProtocol)
protocol IndexServiceProtocol {
    func processBatch(catalogURL: URL, accessBookmarks: [Data], owner: String, withReply reply: @escaping (String?, String?) -> Void)
    func cancel(owner: String, withReply reply: @escaping () -> Void)
}
let connection = NSXPCConnection(serviceName: "me.chichou.ceviche.indexer")
connection.remoteObjectInterface = NSXPCInterface(with: IndexServiceProtocol.self)
connection.activate()
let owner = UUID().uuidString
let proxy = connection.remoteObjectProxyWithErrorHandler { error in
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
} as! IndexServiceProtocol
let bookmarks = CommandLine.arguments.dropFirst().compactMap { path in
    try? URL(fileURLWithPath: path).bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
}
proxy.processBatch(catalogURL: URL(fileURLWithPath: CommandLine.arguments[1]), accessBookmarks: bookmarks, owner: owner) { outcome, error in
    if let error { FileHandle.standardError.write(Data((error + "\n").utf8)); exit(1) }
    print(outcome ?? "missing reply"); connection.invalidate(); exit(outcome == "completed" ? 0 : 2)
}
DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
    proxy.cancel(owner: owner) {}; connection.invalidate(); exit(3)
}
dispatchMain()
