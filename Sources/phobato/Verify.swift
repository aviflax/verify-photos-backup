import ArgumentParser
import Foundation

struct Verify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract:
            "Verify that the local Photos library is fully backed up to a Backblaze B2 bucket."
    )

    @Flag(help: "Also write debug CSVs of the raw bucket and library listings.")
    var debug: Bool = false

    func run() async throws {
        let reportDir = try resolveReportDir()
        errPrint("Report directory: \(reportDir)/\n")
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

        errPrint(
            "Loaded \(fmt(assets.count)) library assets and \(fmt(objects.count)) bucket objects.\n"
        )

        let result = match(assets: assets, objects: objects) {
            processed, total, matched, notFound in
            let percent = total > 0 ? processed * 100 / total : 0
            errPrint(
                "\r\u{1B}[2KMatching: \(fmt(processed)) of \(fmt(total)) (\(percent)%) — \(fmt(matched)) matched, \(fmt(notFound)) not found"
            )
        }
        errPrint("\n")

        try writeMatchResult(
            result,
            matchedPath: "\(reportDir)/matched.csv",
            notFoundPath: "\(reportDir)/assets-not-found-in-bucket.csv"
        )

        print(
            "Matched \(fmt(result.matched.count)) of \(fmt(assets.count)) assets; \(fmt(result.notFound.count)) not found."
        )
        print("Wrote: \(reportDir)/matched.csv, \(reportDir)/assets-not-found-in-bucket.csv")
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
    throw PhobatoError(
        "no available report directory: reports/report-01..reports/report-99 all exist"
    )
}
