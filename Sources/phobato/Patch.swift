import Foundation
import NIOCore
import Photos
import SotoS3

// MARK: - Upload orchestration

func runUploads(
    items: [NotFoundRow],
    patchDir: String,
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
        patchDir: patchDir,
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
        "Patched \(fmt(summary.succeeded)) of \(fmt(summary.total)) assets; \(fmt(summary.skipped)) already in bucket; \(fmt(summary.failed)) failed."
    )
    print("Wrote: \(patchDir)/patched.csv")
    if summary.skipped > 0 {
        print("       \(patchDir)/skipped_already_patched.csv")
    }
    if summary.failed > 0 {
        print("       \(patchDir)/patch_failures.csv")
        print("       \(patchDir)/patch_errors.log")
    }
}

// 1 initial attempt + (maxAttempts - 1) in-process resume attempts.
// On the final attempt, abortOnFail: true so a still-failing upload
// is cleaned up server-side rather than left dangling on B2.
private let maxAttempts = 3
private let multipartPartSize: Int64 = 5 * 1024 * 1024

private func uploadOne(
    item: NotFoundRow,
    bucket: String,
    s3: S3,
    sink: PatchSink
) async {
    let key = bucketKey(for: item)
    do {
        switch try await checkExisting(s3: s3, bucket: bucket, key: key, expectedSize: item.size) {
        case .matches:
            await sink.recordSkipped(item: item, key: key)
            return
        case .mismatch(let bucketSize):
            await sink.recordFailure(
                item: item, key: key,
                error: PhobatoError(sizeMismatchMessage(bucketSize: bucketSize, expected: item.size))
            )
            return
        case .absent:
            break
        }

        let tempURL = try await stageOriginalToTempFile(item: item, sink: sink)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let createReq = S3.CreateMultipartUploadRequest(bucket: bucket, key: key)
        let tracker = BytesTracker()
        let size = item.size
        let totalParts = Int((size + multipartPartSize - 1) / multipartPartSize)

        @Sendable func progress(_ fraction: Double) async throws {
            let cumulative = Int64(fraction * Double(size))
            let delta = await tracker.advance(to: cumulative)
            if delta > 0 { await sink.addBytes(delta) }
        }

        var resumeReq: S3.ResumeMultipartUploadRequest?
        for attempt in 1...maxAttempts {
            let isLast = attempt == maxAttempts
            do {
                // concurrentUploads: 1 — outer concurrency (4 assets) already
                // saturates a typical uplink; running 4×4=16 simultaneous part
                // uploads makes each part slow enough to risk timing out.
                if let r = resumeReq {
                    _ = try await s3.resumeMultipartUpload(
                        r,
                        filename: tempURL.path,
                        concurrentUploads: 1,
                        abortOnFail: isLast,
                        progress: progress
                    )
                } else {
                    _ = try await s3.multipartUpload(
                        createReq,
                        filename: tempURL.path,
                        concurrentUploads: 1,
                        abortOnFail: isLast,
                        progress: progress
                    )
                }
                await sink.recordSuccess(item: item, key: key)
                return
            } catch S3ErrorType.MultipartError.abortedUpload(let next, let underlying) {
                // With abortOnFail=true on the last attempt, Soto rethrows the
                // raw error rather than wrapping it; this branch only fires on
                // non-final attempts.
                let done = next.completedParts.count
                await sink.info(
                    "INFO: resuming upload of \(key) after error\n      \(done)/\(totalParts) parts already uploaded — \(underlying)"
                )
                resumeReq = next
            }
        }
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

// MARK: - Pre-upload existence check

private enum ExistingObject {
    case absent
    case matches
    case mismatch(bucketSize: Int64)
}

private func checkExisting(
    s3: S3, bucket: String, key: String, expectedSize: Int64
) async throws -> ExistingObject {
    do {
        let head = try await s3.headObject(.init(bucket: bucket, key: key))
        let bucketSize = head.contentLength ?? -1
        return bucketSize == expectedSize ? .matches : .mismatch(bucketSize: bucketSize)
    } catch {
        if let aws = error as? AWSErrorType, aws.context?.responseCode == .notFound {
            return .absent
        }
        throw error
    }
}

private func sizeMismatchMessage(bucketSize: Int64, expected: Int64) -> String {
    func mb(_ b: Int64) -> String {
        String(format: "%.2f MB", Double(b) / 1_000_000)
    }
    return "key collision: bucket object: \(mb(bucketSize)); library asset original: \(mb(expected))"
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

private func stageOriginalToTempFile(item: NotFoundRow, sink: PatchSink) async throws -> URL {
    let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [item.localId], options: nil)
    guard let asset = fetch.firstObject else {
        throw PhobatoError("PhotoKit: no asset found for local_id \(item.localId)")
    }
    let resources = PHAssetResource.assetResources(for: asset)
    var original: PHAssetResource?
    for r in resources where r.type == .photo || r.type == .video {
        original = r
        break
    }
    guard let resource = original else {
        throw PhobatoError("PhotoKit: no photo/video resource for asset \(item.localId)")
    }

    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("phobato-patch-\(UUID().uuidString)")
    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = true
    // PhotoKit fires this only when it has to fetch from iCloud — locally
    // available resources never tick. Sink dedupes so we INFO-log once per
    // asset and update the live counter on first signal.
    options.progressHandler = { fraction in
        Task { await sink.noteDownloadProgress(item: item, fraction: fraction) }
    }

    do {
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
    } catch {
        await sink.noteDownloadFinished(item: item)
        throw error
    }
    await sink.noteDownloadFinished(item: item)
    return tempURL
}

// MARK: - Output sink

actor PatchSink {
    struct Summary {
        let total: Int
        let succeeded: Int
        let skipped: Int
        let failed: Int
    }

    private struct DownloadState {
        let size: Int64
        var fraction: Double
        var lastRenderedPct: Int
    }

    private let total: Int
    private let totalBytes: Int64
    private var completed = 0
    private var succeeded = 0
    private var skipped = 0
    private var failed = 0
    private var bytesUploaded: Int64 = 0
    // Currently in-flight iCloud downloads. The progress segment in the line
    // aggregates over this dict (downloaded / total MB and percent). The
    // separate `downloadStartedFor` set is wider: it remembers every local
    // ID that ever fired progressHandler, so we only emit the one-shot INFO
    // line per asset and so a stale tick after finish doesn't re-add it.
    private var downloads: [String: DownloadState] = [:]
    private var downloadStartedFor: Set<String> = []
    private let patchedHandle: FileHandle
    private let skippedHandle: FileHandle
    private let failuresHandle: FileHandle
    private let errorLogHandle: FileHandle
    private let isoFormatter: ISO8601DateFormatter
    private let nf: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()
    private var closed = false
    private var lastRenderedLineLength = 0

    init(patchDir: String, total: Int, totalBytes: Int64) throws {
        self.total = total
        self.totalBytes = totalBytes
        self.patchedHandle = try openCSV(
            at: "\(patchDir)/patched.csv",
            header: "sequence,creation_date,original_filename,size,local_id,cloud_id,bucket_key"
        )
        self.skippedHandle = try openCSV(
            at: "\(patchDir)/skipped_already_patched.csv",
            header: "sequence,creation_date,original_filename,size,local_id,cloud_id,bucket_key"
        )
        self.failuresHandle = try openCSV(
            at: "\(patchDir)/patch_failures.csv",
            header:
                "sequence,creation_date,original_filename,size,local_id,cloud_id,bucket_key,error"
        )
        let logPath = "\(patchDir)/patch_errors.log"
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

    func info(_ message: String) {
        // Erase the in-place progress line, write the message + newline,
        // then re-render the progress line below.
        FileHandle.standardError.write(Data("\r\u{1B}[2K\(message)\n".utf8))
        render()
    }

    /// Called from PHAssetResourceRequestOptions.progressHandler. The first
    /// firing for a given local ID is the signal that an iCloud download
    /// kicked in (locally-available resources never fire this). Subsequent
    /// firings update the fraction, throttled to whole-percent changes.
    func noteDownloadProgress(item: NotFoundRow, fraction: Double) {
        let pct = Int(fraction * 100)
        if var state = downloads[item.localId] {
            guard pct != state.lastRenderedPct else {
                state.fraction = fraction
                downloads[item.localId] = state
                return
            }
            state.fraction = fraction
            state.lastRenderedPct = pct
            downloads[item.localId] = state
            render()
            return
        }
        // First tick for this asset — but it could also be a stale tick after
        // writeData already returned (Tasks dispatched from progressHandler are
        // not ordered with respect to noteDownloadFinished). The startedFor
        // dedupe guards against re-adding a finished asset.
        guard !downloadStartedFor.contains(item.localId) else { return }
        downloadStartedFor.insert(item.localId)
        downloads[item.localId] = DownloadState(
            size: item.size, fraction: fraction, lastRenderedPct: pct
        )
        // Permanent record in the scrollback so a slow run is explainable.
        FileHandle.standardError.write(Data(
            "\r\u{1B}[2KINFO: \(item.originalFilename) (\(item.localId)): downloading from iCloud (offloaded)\n".utf8
        ))
        render()
    }

    func noteDownloadFinished(item: NotFoundRow) {
        if downloads.removeValue(forKey: item.localId) != nil {
            render()
        }
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

    func recordSkipped(item: NotFoundRow, key: String) {
        completed += 1
        skipped += 1
        // Credit skipped bytes toward bytesUploaded so the MB-progress reaches
        // 100% at end of run — those bytes are already in the bucket.
        bytesUploaded += item.size
        let row = "\(skipped)/\(total),"
            + "\(isoFormatter.string(from: item.creationDate)),"
            + "\(csvField(item.originalFilename)),"
            + "\(item.size),"
            + "\(csvField(item.localId)),"
            + "\(csvField(item.cloudId)),"
            + "\(csvField(key))\n"
        skippedHandle.write(Data(row.utf8))
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
            return Summary(total: total, succeeded: succeeded, skipped: skipped, failed: failed)
        }
        closed = true
        FileHandle.standardError.write(Data("\n".utf8))
        try? patchedHandle.close()
        try? skippedHandle.close()
        try? failuresHandle.close()
        try? errorLogHandle.close()
        return Summary(total: total, succeeded: succeeded, skipped: skipped, failed: failed)
    }

    private func render() {
        let percent = total > 0 ? completed * 100 / total : 0
        func fmt(_ n: Int) -> String { nf.string(for: n) ?? "\(n)" }
        // Use decimal MB (1,000,000 bytes) — matches the convention macOS Finder
        // uses for file sizes, so the numbers line up with what users see there.
        let mbDone = Int(bytesUploaded / 1_000_000)
        let mbTotal = Int(totalBytes / 1_000_000)
        let bytePercent = totalBytes > 0
            ? Int((Double(bytesUploaded) / Double(totalBytes)) * 100)
            : 0
        var line =
            "Patching: \(fmt(completed)) of \(fmt(total)) (\(percent)%) — \(fmt(succeeded)) succeeded, \(fmt(skipped)) skipped, \(fmt(failed)) failed — \(fmt(mbDone)) of \(fmt(mbTotal)) MB (\(bytePercent)%)"
        if !downloads.isEmpty {
            // Aggregate over currently in-flight downloads. As assets finish
            // they drop out of the dict; as new ones start they're added in.
            let dlTotal = downloads.values.reduce(Int64(0)) { $0 + $1.size }
            let dlDone = downloads.values.reduce(Int64(0)) {
                $0 + Int64($1.fraction * Double($1.size))
            }
            let dlMbDone = Int(dlDone / 1_000_000)
            let dlMbTotal = Int(dlTotal / 1_000_000)
            let dlPct = dlTotal > 0 ? Int(Double(dlDone) / Double(dlTotal) * 100) : 0
            line +=
                " — \(downloads.count) downloading from iCloud: \(fmt(dlMbDone)) of \(fmt(dlMbTotal)) MB (\(dlPct)%)"
        }
        FileHandle.standardError.write(Data("\r\u{1B}[2K\(line)".utf8))
        lastRenderedLineLength = line.count
    }
}

// MARK: - Patch dir creation

func createNextPatchDir(in reportDir: String) throws -> String {
    let fm = FileManager.default
    let entries = (try? fm.contentsOfDirectory(atPath: reportDir)) ?? []
    let highest = entries.compactMap { name -> Int? in
        guard name.hasPrefix("patch-") else { return nil }
        return Int(name.dropFirst("patch-".count))
    }.max() ?? 0
    let next = highest + 1
    guard next <= 99 else {
        throw PhobatoError(
            "patch numbering exhausted: \(reportDir)/patch-99 already exists"
        )
    }
    let path = "\(reportDir)/" + String(format: "patch-%02d", next)
    try fm.createDirectory(atPath: path, withIntermediateDirectories: false)
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

