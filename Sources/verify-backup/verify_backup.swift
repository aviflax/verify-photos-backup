import Foundation

struct VerifyBackupError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

func eprint(_ s: String) {
    FileHandle.standardError.write(Data(s.utf8))
}

@main
struct VerifyBackup {
    static func main() async {
        do {
            try await run()
        } catch {
            eprint("\(error)\n")
            exit(1)
        }
    }

    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let debug = args.contains("--debug")

        let bucketDebugPath: String? = debug ? "bucket-objects.csv" : nil
        let libraryDebugPath: String? = debug ? "library-assets.csv" : nil

        let config = try b2ConfigFromEnv()

        async let bucketTask = fetchBucketObjects(
            config: config, debugCSVPath: bucketDebugPath
        )
        async let libraryTask = fetchLibraryAssets(debugCSVPath: libraryDebugPath)

        let (objects, assets) = try await (bucketTask, libraryTask)

        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        func fmt(_ n: Int) -> String { nf.string(for: n) ?? "\(n)" }

        eprint("Loaded \(fmt(assets.count)) library assets and \(fmt(objects.count)) bucket objects.\n")

        let result = match(assets: assets, objects: objects) { processed, total, matched, notFound in
            let percent = total > 0 ? processed * 100 / total : 0
            eprint(
                "\r\u{1B}[2KMatching: \(fmt(processed)) of \(fmt(total)) (\(percent)%) — \(fmt(matched)) matched, \(fmt(notFound)) not found"
            )
        }
        eprint("\n")

        try writeMatchResult(result, matchedPath: "matched.csv", notFoundPath: "not-found.csv")

        print(
            "Matched \(fmt(result.matched.count)) of \(fmt(assets.count)) assets; \(fmt(result.notFound.count)) not found."
        )
        print("Wrote: matched.csv, not-found.csv")
        if debug {
            print("Debug CSVs: bucket-objects.csv, library-assets.csv")
        }
    }
}
