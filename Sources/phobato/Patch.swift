import ArgumentParser
import Foundation
import NIOCore
import Photos
import SotoS3

struct Patch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "patch",
        abstract:
            "Upload library assets that the most recent verify run found missing from the bucket."
    )

    func run() async throws {
        let reportDir = try findRecentReportDir()
        errPrint("Using report directory: \(reportDir)/\n")

        let notFoundPath = "\(reportDir)/assets-not-found-in-bucket.csv"
        let rows = try parseNotFoundCSV(at: notFoundPath)
        let (uploadable, missingCloudId) = rows.partitioned { !$0.cloudId.isEmpty }

        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        func fmt(_ n: Int) -> String { nf.string(for: n) ?? "\(n)" }

        if uploadable.isEmpty {
            print("Nothing to upload (\(fmt(rows.count)) rows; \(fmt(missingCloudId.count)) lack a cloud identifier).")
            return
        }

        print("Found \(fmt(uploadable.count)) missing assets to upload.")
        if !missingCloudId.isEmpty {
            print("(\(fmt(missingCloudId.count)) rows lack a cloud_id and will be skipped.)")
        }
        print("Proceed with upload? [y/N] ", terminator: "")
        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(),
              answer == "y" || answer == "yes"
        else {
            print("Aborted.")
            return
        }

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw PhobatoError("Photos access not granted (status: \(status.rawValue))")
        }

        let config = try b2ConfigFromEnv()
        let client = AWSClient(
            credentialProvider: .static(accessKeyId: config.keyId, secretAccessKey: config.appKey)
        )
        do {
            try await runUploads(
                items: uploadable,
                reportDir: reportDir,
                config: config,
                client: client
            )
            try await client.shutdown()
        } catch {
            try? await client.shutdown()
            throw error
        }
    }
}

// MARK: - Upload orchestration

private func runUploads(
    items: [NotFoundRow],
    reportDir: String,
    config: B2Config,
    client: AWSClient
) async throws {
    // Soto's default per-HTTP-request timeout is 20s, which is too tight for
    // a multipart part on a typical home uplink (~5MB parts) and causes
    // HTTPClientError.deadlineExceeded on larger originals (videos, big PNGs).
    let s3 = S3(
        client: client,
        region: Region(rawValue: config.region),
        endpoint: config.endpoint,
        timeout: .minutes(5)
    )

    let totalBytes = items.reduce(Int64(0)) { $0 + $1.size }
    let sink = try PatchSink(
        reportDir: reportDir,
        total: items.count,
        totalBytes: totalBytes
    )

    let concurrency = 4
    await withTaskGroup(of: Void.self) { group in
        var nextIndex = 0
        let initial = min(concurrency, items.count)
        for _ in 0..<initial {
            let item = items[nextIndex]
            nextIndex += 1
            group.addTask {
                await uploadOne(item: item, bucket: config.bucket, s3: s3, sink: sink)
            }
        }
        while await group.next() != nil {
            if nextIndex < items.count {
                let item = items[nextIndex]
                nextIndex += 1
                group.addTask {
                    await uploadOne(item: item, bucket: config.bucket, s3: s3, sink: sink)
                }
            }
        }
    }

    let summary = await sink.close()
    let nf = NumberFormatter()
    nf.numberStyle = .decimal
    func fmt(_ n: Int) -> String { nf.string(for: n) ?? "\(n)" }
    print(
        "Patched \(fmt(summary.succeeded)) of \(fmt(summary.total)) assets; \(fmt(summary.failed)) failed."
    )
    print("Wrote: \(reportDir)/patched.csv")
    if summary.failed > 0 {
        print("       \(reportDir)/patch_failures.csv")
        print("       \(reportDir)/patch_errors.log")
    }
}

private func uploadOne(
    item: NotFoundRow,
    bucket: String,
    s3: S3,
    sink: PatchSink
) async {
    let key = bucketKey(for: item)
    do {
        let tempURL = try await stageOriginalToTempFile(localId: item.localId)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let createReq = S3.CreateMultipartUploadRequest(bucket: bucket, key: key)
        let tracker = BytesTracker()
        let size = item.size
        // concurrentUploads: 1 — outer concurrency (4 assets) already saturates
        // a typical uplink; running 4×4=16 simultaneous part uploads makes each
        // part slow enough to risk timing out.
        _ = try await s3.multipartUpload(
            createReq, filename: tempURL.path, concurrentUploads: 1
        ) { fraction in
            let cumulative = Int64(fraction * Double(size))
            let delta = await tracker.advance(to: cumulative)
            if delta > 0 { await sink.addBytes(delta) }
        }
        await sink.recordSuccess(item: item, key: key)
    } catch {
        await sink.recordFailure(item: item, key: key, error: error)
    }
}

private actor BytesTracker {
    private var sent: Int64 = 0
    func advance(to cumulative: Int64) -> Int64 {
        let delta = cumulative - sent
        guard delta > 0 else { return 0 }
        sent = cumulative
        return delta
    }
}

// MARK: - Object key construction

func bucketKey(for row: NotFoundRow) -> String {
    let datePrefix = datePrefixFormatter.string(from: row.creationDate)
    let core = row.cloudId
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    let ext = normalizedExtension(forFilename: row.originalFilename)
    return "\(datePrefix)/\(core).\(ext)"
}

private let datePrefixFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy/MM/dd"
    f.timeZone = .current
    return f
}()

private func normalizedExtension(forFilename name: String) -> String {
    let dot = name.lastIndex(of: ".")
    let raw = dot.map { String(name[name.index(after: $0)...]) } ?? ""
    let lower = raw.lowercased()
    switch lower {
    case "jpg": return "jpeg"
    case "tif": return "tiff"
    default: return lower
    }
}

// MARK: - PhotoKit data fetch

private func stageOriginalToTempFile(localId: String) async throws -> URL {
    let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil)
    guard let asset = fetch.firstObject else {
        throw PhobatoError("PhotoKit: no asset found for local_id \(localId)")
    }
    let resources = PHAssetResource.assetResources(for: asset)
    var original: PHAssetResource?
    for r in resources where r.type == .photo || r.type == .video {
        original = r
        break
    }
    guard let resource = original else {
        throw PhobatoError("PhotoKit: no photo/video resource for asset \(localId)")
    }

    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("phobato-patch-\(UUID().uuidString)")
    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = true

    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        PHAssetResourceManager.default().writeData(
            for: resource, toFile: tempURL, options: options
        ) { error in
            if let error = error {
                cont.resume(throwing: error)
            } else {
                cont.resume(returning: ())
            }
        }
    }
    return tempURL
}

// MARK: - Output sink

actor PatchSink {
    struct Summary {
        let total: Int
        let succeeded: Int
        let failed: Int
    }

    private let total: Int
    private let totalBytes: Int64
    private var completed = 0
    private var succeeded = 0
    private var failed = 0
    private var bytesUploaded: Int64 = 0
    private let patchedHandle: FileHandle
    private let failuresHandle: FileHandle
    private let errorLogHandle: FileHandle
    private let isoFormatter: ISO8601DateFormatter
    private var closed = false
    private var lastRenderedLineLength = 0

    init(reportDir: String, total: Int, totalBytes: Int64) throws {
        self.total = total
        self.totalBytes = totalBytes
        self.patchedHandle = try openCSV(
            at: "\(reportDir)/patched.csv",
            header: "sequence,creation_date,original_filename,size,local_id,cloud_id,bucket_key"
        )
        self.failuresHandle = try openCSV(
            at: "\(reportDir)/patch_failures.csv",
            header:
                "sequence,creation_date,original_filename,size,local_id,cloud_id,bucket_key,error"
        )
        let logPath = "\(reportDir)/patch_errors.log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        guard let log = FileHandle(forWritingAtPath: logPath) else {
            throw PhobatoError("cannot open \(logPath) for writing")
        }
        self.errorLogHandle = log
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        self.isoFormatter = f
    }

    func addBytes(_ delta: Int64) {
        bytesUploaded += delta
        render()
    }

    func recordSuccess(item: NotFoundRow, key: String) {
        completed += 1
        succeeded += 1
        let row = "\(succeeded)/\(total),"
            + "\(isoFormatter.string(from: item.creationDate)),"
            + "\(csvField(item.originalFilename)),"
            + "\(item.size),"
            + "\(csvField(item.localId)),"
            + "\(csvField(item.cloudId)),"
            + "\(csvField(key))\n"
        patchedHandle.write(Data(row.utf8))
        render()
    }

    func recordFailure(item: NotFoundRow, key: String, error: Error) {
        completed += 1
        failed += 1
        let message = String(describing: error)
        let row = "\(failed)/\(total),"
            + "\(isoFormatter.string(from: item.creationDate)),"
            + "\(csvField(item.originalFilename)),"
            + "\(csvField(item.size.description)),"
            + "\(csvField(item.localId)),"
            + "\(csvField(item.cloudId)),"
            + "\(csvField(key)),"
            + "\(csvField(message))\n"
        failuresHandle.write(Data(row.utf8))
        let logLine =
            "[\(isoFormatter.string(from: Date()))] \(item.localId) -> \(key): \(message)\n"
        errorLogHandle.write(Data(logLine.utf8))
        render()
    }

    func close() -> Summary {
        guard !closed else {
            return Summary(total: total, succeeded: succeeded, failed: failed)
        }
        closed = true
        FileHandle.standardError.write(Data("\n".utf8))
        try? patchedHandle.close()
        try? failuresHandle.close()
        try? errorLogHandle.close()
        return Summary(total: total, succeeded: succeeded, failed: failed)
    }

    private func render() {
        let percent = total > 0 ? completed * 100 / total : 0
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        func fmt(_ n: Int) -> String { nf.string(for: n) ?? "\(n)" }
        // Use decimal MB (1,000,000 bytes) — matches the convention macOS Finder
        // uses for file sizes, so the numbers line up with what users see there.
        let mbDone = Int(bytesUploaded / 1_000_000)
        let mbTotal = Int(totalBytes / 1_000_000)
        let bytePercent = totalBytes > 0
            ? Int((Double(bytesUploaded) / Double(totalBytes)) * 100)
            : 0
        let line =
            "Patching: \(fmt(completed)) of \(fmt(total)) (\(percent)%) — \(fmt(succeeded)) succeeded, \(fmt(failed)) failed — \(fmt(mbDone)) of \(fmt(mbTotal)) MB (\(bytePercent)%)"
        FileHandle.standardError.write(Data("\r\u{1B}[2K\(line)".utf8))
        lastRenderedLineLength = line.count
    }
}

// MARK: - Report dir discovery

private func findRecentReportDir() throws -> String {
    let fm = FileManager.default
    let entries: [String]
    do {
        entries = try fm.contentsOfDirectory(atPath: "reports")
    } catch {
        throw PhobatoError("cannot read reports/: \(error)")
    }
    let candidates = entries
        .filter { $0.hasPrefix("report-") }
        .sorted()
    guard let latest = candidates.last else {
        throw PhobatoError("no report directories found in reports/")
    }
    let path = "reports/\(latest)"
    let attrs = try fm.attributesOfItem(atPath: path)
    let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
    let age = Date().timeIntervalSince(mtime)
    guard age <= 3600 else {
        let mins = Int(age / 60)
        throw PhobatoError(
            "most recent report (\(path)) is \(mins) minutes old; patch only operates on reports created in the past hour. Run `phobato verify` first."
        )
    }
    return path
}

// MARK: - CSV parsing

struct NotFoundRow: Sendable {
    let creationDate: Date
    let originalFilename: String
    let size: Int64
    let localId: String
    let cloudId: String
}

private func parseNotFoundCSV(at path: String) throws -> [NotFoundRow] {
    let data: String
    do {
        data = try String(contentsOfFile: path, encoding: .utf8)
    } catch {
        throw PhobatoError("cannot read \(path): \(error)")
    }
    var lines = data.split(separator: "\n", omittingEmptySubsequences: true)
        .map(String.init)
    guard !lines.isEmpty else { return [] }
    lines.removeFirst()  // header

    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime]

    var rows: [NotFoundRow] = []
    rows.reserveCapacity(lines.count)
    for (i, line) in lines.enumerated() {
        let fields = parseCSVLine(line)
        guard fields.count >= 5 else {
            throw PhobatoError("malformed row \(i + 2) in \(path): expected 5 fields, got \(fields.count)")
        }
        guard let date = isoFormatter.date(from: fields[0]) else {
            throw PhobatoError("malformed creation_date on row \(i + 2): \(fields[0])")
        }
        guard let size = Int64(fields[2]) else {
            throw PhobatoError("malformed size on row \(i + 2): \(fields[2])")
        }
        rows.append(
            NotFoundRow(
                creationDate: date,
                originalFilename: fields[1],
                size: size,
                localId: fields[3],
                cloudId: fields[4]
            )
        )
    }
    return rows
}

private func parseCSVLine(_ line: String) -> [String] {
    var fields: [String] = []
    var current = ""
    var inQuotes = false
    var i = line.startIndex
    while i < line.endIndex {
        let c = line[i]
        if inQuotes {
            if c == "\"" {
                let next = line.index(after: i)
                if next < line.endIndex && line[next] == "\"" {
                    current.append("\"")
                    i = line.index(after: next)
                    continue
                }
                inQuotes = false
                i = next
                continue
            }
            current.append(c)
            i = line.index(after: i)
        } else {
            if c == "," {
                fields.append(current)
                current = ""
                i = line.index(after: i)
                continue
            }
            if c == "\"" && current.isEmpty {
                inQuotes = true
                i = line.index(after: i)
                continue
            }
            current.append(c)
            i = line.index(after: i)
        }
    }
    fields.append(current)
    return fields
}

private extension Array {
    func partitioned(_ predicate: (Element) -> Bool) -> (matching: [Element], rest: [Element]) {
        var yes: [Element] = []
        var no: [Element] = []
        for e in self {
            if predicate(e) { yes.append(e) } else { no.append(e) }
        }
        return (yes, no)
    }
}
