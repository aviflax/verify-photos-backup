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

        let reportDir = try resolveReportDir()
        eprint("Report directory: \(reportDir)/\n")
        let bucketDebugPath = debug ? "\(reportDir)/bucket-objects.csv" : nil
        let libraryDebugPath = debug ? "\(reportDir)/library-assets.csv" : nil

        let config = try b2ConfigFromEnv()

        let reporter = ProgressReporter()
        async let bucketTask = fetchBucketObjects(
            config: config, reporter: reporter, debugCSVPath: bucketDebugPath
        )
        async let libraryTask = fetchLibraryAssets(
            reporter: reporter, debugCSVPath: libraryDebugPath
        )

        let objects: [BucketObject]
        let assets: [LibraryAsset]
        do {
            objects = try await bucketTask
            assets = try await libraryTask
        } catch {
            await reporter.finish()
            throw error
        }
        await reporter.finish()

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

        try writeMatchResult(
            result,
            matchedPath: "\(reportDir)/matched.csv",
            notFoundPath: "\(reportDir)/asset-not-found-in-bucket.csv"
        )

        print(
            "Matched \(fmt(result.matched.count)) of \(fmt(assets.count)) assets; \(fmt(result.notFound.count)) not found."
        )
        print("Wrote: \(reportDir)/matched.csv, \(reportDir)/asset-not-found-in-bucket.csv")
        if debug {
            print("Debug CSVs: \(reportDir)/bucket-objects.csv, \(reportDir)/library-assets.csv")
        }
    }
}

private func resolveReportDir() throws -> String {
    let fm = FileManager.default
    try fm.createDirectory(atPath: "reports", withIntermediateDirectories: true)
    for i in 1...99 {
        let candidate = "reports/" + String(format: "report-%02d", i)
        if !fm.fileExists(atPath: candidate) {
            try fm.createDirectory(atPath: candidate, withIntermediateDirectories: false)
            return candidate
        }
    }
    throw VerifyBackupError(
        "no available report directory: reports/report-01..reports/report-99 all exist"
    )
}
