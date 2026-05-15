import ArgumentParser
import Foundation
import SotoS3

struct Go: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "go",
        abstract: "Verify the backup and optionally upload any missing assets."
    )

    @Flag(help: "Also write debug CSVs of the raw bucket and library listings.")
    var debug: Bool = false

    func run() async throws {
        // MARK: Verify phase

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
        let missingCloudId = notFoundRows.filter { $0.cloudId.isEmpty }

        if uploadable.isEmpty {
            print(
                "Nothing to upload (\(fmt(notFoundRows.count)) missing; \(fmt(missingCloudId.count)) lack a cloud identifier)."
            )
            return
        }

        print("Found \(fmt(uploadable.count)) missing assets to upload.")
        if !missingCloudId.isEmpty {
            print("(\(fmt(missingCloudId.count)) assets lack a cloud_id and will be skipped.)")
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
