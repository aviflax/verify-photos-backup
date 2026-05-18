import ArgumentParser
import Foundation
import SotoS3

struct PhobatoError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

func errPrint(_ s: String) {
    FileHandle.standardError.write(Data(s.utf8))
}

@main
struct Phobato: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "phobato",
        abstract: "PHOto BAckup TOol for working with backups of Apple Photos libraries in S3-compatible buckets"
    )

    @Flag(help: "Also write debug CSVs of the raw bucket and library listings.")
    var debug: Bool = false

    func run() async throws {
        // MARK: Verify phase

        let reportDir = try resolveReportDir()
        errPrint("Report directory: \(reportDir)/\n")
        let bucketDebugPath = debug ? "\(reportDir)/bucket-objects.csv" : nil
        let libraryDebugPath = debug ? "\(reportDir)/library-assets.csv" : nil

        let config = try bucketConfigFromEnv()

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

        let result = match(assets: assets, objects: objects) { processed, total, matched, notFound in
            let percent = total > 0 ? processed * 100 / total : 0
            errPrint(
                "\r\u{1B}[2KMatching: \(fmt(processed)) of \(fmt(total)) (\(percent)%) — \(fmt(matched)) matched, \(fmt(notFound)) not found"
            )
        }
        errPrint("\n")

        let enriched = MatchResult(
            matched: result.matched,
            notFound: populateCloudIdentifiers(for: result.notFound)
        )

        let matchedPath: String? = debug ? "\(reportDir)/matched.csv" : nil
        let notFoundPath: String? = enriched.notFound.isEmpty ? nil : "\(reportDir)/assets-not-found-in-bucket.csv"
        try writeMatchResult(enriched, matchedPath: matchedPath, notFoundPath: notFoundPath)

        print(
            "Matched \(fmt(result.matched.count)) of \(fmt(assets.count)) assets; \(fmt(result.notFound.count)) not found."
        )
        var written: [String] = []
        if let p = notFoundPath { written.append(p) }
        if let p = matchedPath { written.append(p) }
        if debug {
            written.append("\(reportDir)/bucket-objects.csv")
            written.append("\(reportDir)/library-assets.csv")
        }
        if !written.isEmpty {
            print("Wrote: \(written.joined(separator: ", "))")
        }

        // MARK: Patch phase

        guard !enriched.notFound.isEmpty else {
            print("All assets are in the bucket. Nothing to patch.")
            return
        }

        // Convert in memory — no CSV round-trip.
        let notFoundRows = enriched.notFound.map { asset in
            NotFoundRow(
                creationDate: asset.creationDate,
                originalFilename: asset.originalFilename,
                size: asset.size,
                localId: asset.localIdentifier,
                cloudId: asset.cloudIdentifier ?? ""
            )
        }
        let uploadable = notFoundRows.filter { !$0.cloudId.isEmpty }
        let missingCloudIdCount = notFoundRows.count - uploadable.count

        if uploadable.isEmpty {
            print(
                "Nothing to upload (\(fmt(notFoundRows.count)) missing; \(fmt(missingCloudIdCount)) lack a cloud identifier)."
            )
            return
        }

        print("Found \(fmt(uploadable.count)) missing assets to upload.")
        if missingCloudIdCount > 0 {
            print("(\(fmt(missingCloudIdCount)) assets lack a cloud_id and will be skipped.)")
        }
        print("Proceed with upload? [y/N] ", terminator: "")
        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(),
              answer == "y" || answer == "yes"
        else {
            print("Aborted.")
            return
        }

        let patchDir = try createNextPatchDir(in: reportDir)
        errPrint("Writing patch outputs to: \(patchDir)/\n")

        let client = AWSClient(
            credentialProvider: .static(accessKeyId: config.keyId, secretAccessKey: config.appKey)
        )
        do {
            try await runUploads(items: uploadable, patchDir: patchDir, config: config, client: client)
            try await client.shutdown()
        } catch {
            try? await client.shutdown()
            throw error
        }
    }
}

private func resolveReportDir() throws -> String {
    let fm = FileManager.default
    try fm.createDirectory(atPath: "reports", withIntermediateDirectories: true)
    // Use one-higher-than-the-highest-existing rather than first-empty-slot,
    // so deleting old report dirs (e.g. report-01) doesn't cause the next run
    // to recycle that name when newer reports are still around.
    let entries = (try? fm.contentsOfDirectory(atPath: "reports")) ?? []
    let highest = entries.compactMap { name -> Int? in
        guard name.hasPrefix("report-") else { return nil }
        return Int(name.dropFirst("report-".count))
    }.max() ?? 0
    let next = highest + 1
    guard next <= 99 else {
        throw PhobatoError(
            "report numbering exhausted: reports/report-99 already exists"
        )
    }
    let path = "reports/" + String(format: "report-%02d", next)
    try fm.createDirectory(atPath: path, withIntermediateDirectories: false)
    return path
}
