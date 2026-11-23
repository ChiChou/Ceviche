import AppKit
import CevicheCore

/// Command-line options for scripts and automation: create or open a catalog and import photos into it.
/// Terminal output stays in English, like other command-line tools.
struct LaunchOptions: Equatable {
    var catalog: URL
    /// `--new-catalog`: the package is created; it must not exist yet.
    var create: Bool
    var imports: [URL] = []
    var mode: CatalogImporter.ImportMode = .reference
    /// `--quit-when-done`: quit once the catalog is open and the import has finished, with a non-zero status on failure.
    var quitWhenDone = false

    struct UsageError: Error, Equatable, CustomStringConvertible { var description: String }
    enum Outcome: Equatable {
        /// No catalog option: a photo path on its own opens in Detail, as before.
        case none
        case help
        case run(LaunchOptions)
    }

    static let usage = """
    Usage: Ceviche --new-catalog <path.cevichecatalog> [--copy | --reference] [--quit-when-done] [<photo or folder>...]
           Ceviche --catalog <path.cevichecatalog> [--copy | --reference] [--quit-when-done] [<photo or folder>...]
           Ceviche <photo>

      --new-catalog <path>  Create an empty catalog and open it (.cevichecatalog is appended if missing)
      --catalog <path>      Open an existing catalog
      --reference           Import originals in place (default)
      --copy                Copy originals into the catalog
      --quit-when-done      Quit after the import; exit status 1 if a file failed or the import stopped
      -h, --help            Show this help

    Folders are imported with their subfolders. Use absolute paths with `open -a Ceviche --args`.
    """

    /// The options this process was launched with; set once at startup, before any window opens.
    nonisolated(unsafe) static var current: LaunchOptions?

    /// Single-dash arguments are AppKit defaults (`-NSDocumentRevisionsDebugMode YES`, `-ApplePersistenceIgnoreState YES`)
    /// and take a value; `-psn_…` from older launches does not.
    static func parse(_ arguments: [String], currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                      fileExists: (URL) -> (exists: Bool, isDirectory: Bool) = Self.fileStatus) throws -> Outcome {
        var catalog: (path: String, create: Bool)?
        var mode: CatalogImporter.ImportMode?
        var quitWhenDone = false
        var positional: [String] = []
        var index = 0, optionsEnded = false
        func value(for flag: String) throws -> String {
            index += 1
            guard index < arguments.count, !arguments[index].isEmpty, !arguments[index].hasPrefix("-") else { throw UsageError(description: "\(flag) needs a path.") }
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            if optionsEnded || !argument.hasPrefix("-") || argument == "-" {
                positional.append(argument)
            } else if argument == "--" {
                optionsEnded = true
            } else if argument.hasPrefix("--") {
                switch argument {
                case "--help": return .help
                case "--new-catalog", "--catalog":
                    guard catalog == nil else { throw UsageError(description: "Give one of --new-catalog or --catalog, once.") }
                    catalog = (try value(for: argument), argument == "--new-catalog")
                case "--copy", "--reference":
                    let chosen: CatalogImporter.ImportMode = argument == "--copy" ? .copy : .reference
                    guard mode == nil || mode == chosen else { throw UsageError(description: "Give one of --copy or --reference.") }
                    mode = chosen
                case "--quit-when-done": quitWhenDone = true
                default: throw UsageError(description: "Unknown option \(argument).")
                }
            } else if argument == "-h" {
                return .help
            } else if !argument.hasPrefix("-psn_") {
                index += 1 // An AppKit default and its value.
            }
            index += 1
        }
        guard let catalog else {
            if mode != nil { throw UsageError(description: "--copy and --reference need --new-catalog or --catalog.") }
            if quitWhenDone { throw UsageError(description: "--quit-when-done needs --new-catalog or --catalog.") }
            return .none
        }
        func resolve(_ path: String) -> URL {
            let expanded = (path as NSString).expandingTildeInPath
            return (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : currentDirectory.appendingPathComponent(expanded)).standardizedFileURL
        }
        var root = resolve(catalog.path)
        if catalog.create {
            if root.pathExtension.lowercased() != "cevichecatalog" { root.appendPathExtension("cevichecatalog") }
            guard !fileExists(root).exists else { throw UsageError(description: "\(root.path) already exists.") }
            let parent = fileExists(root.deletingLastPathComponent())
            guard parent.exists, parent.isDirectory else { throw UsageError(description: "Folder \(root.deletingLastPathComponent().path) does not exist.") }
        } else {
            guard fileExists(root.appendingPathComponent("catalog.sqlite")).exists else { throw UsageError(description: "\(root.path) is not a Ceviche catalog.") }
        }
        let imports = positional.map(resolve)
        if let missing = imports.first(where: { !fileExists($0).exists }) { throw UsageError(description: "\(missing.path) does not exist.") }
        return .run(LaunchOptions(catalog: root, create: catalog.create, imports: imports, mode: mode ?? .reference, quitWhenDone: quitWhenDone))
    }

    static func fileStatus(_ url: URL) -> (exists: Bool, isDirectory: Bool) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return (exists, isDirectory.boolValue)
    }

    /// The status `--quit-when-done` exits with; `AppDelegate` applies it once the app has saved and is terminating.
    nonisolated(unsafe) static var exitStatus: Int32?

    /// Prints what the import did, failures to standard error, then quits.
    @MainActor static func report(_ summary: CatalogModel.ImportSummary) {
        var line = "Imported \(summary.imported)"
        if summary.duplicates > 0 { line += ", \(summary.duplicates) already in the catalog" }
        if summary.inTrash > 0 { line += ", \(summary.inTrash) already in Trash" }
        if !summary.failures.isEmpty { line += ", \(summary.failures.count) failed" }
        if summary.stopped { line += ", stopped" }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
        for failure in summary.failures { FileHandle.standardError.write(Data("Ceviche: \(failure.path): \(failure.reason)\n".utf8)) }
        quit(status: summary.failures.isEmpty && !summary.stopped ? 0 : 1)
    }

    /// Quits through the normal path, so pending catalog edits are saved first.
    @MainActor static func quit(status: Int32) {
        exitStatus = status
        // From the run loop, not the main queue or a Task: the app's quit handler finishes on the main actor while
        // `terminate` waits, and a main-queue caller would block it.
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }

    /// Parses this process's arguments; help and usage errors print and exit before the app starts.
    static func resolveAtLaunch() {
        do {
            switch try parse(Array(ProcessInfo.processInfo.arguments.dropFirst())) {
            case .none: break
            case .help: print(usage); exit(0)
            case .run(let options):
                current = options
                // Otherwise AppKit hands the paths to `application(_:open:)` as files to open, and the main window never
                // opens; restored state from a killed run can also leave the app with no window.
                UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO", "ApplePersistenceIgnoreState": true])
            }
        } catch {
            FileHandle.standardError.write(Data("Ceviche: \(error)\nRun Ceviche --help for usage.\n".utf8))
            exit(64) // EX_USAGE
        }
    }
}
