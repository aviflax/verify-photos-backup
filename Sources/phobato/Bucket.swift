import Foundation
import SotoS3

struct BucketObject: Sendable {
    let key: String
    let size: Int64
    let lastModified: Date
}

struct B2Config: Sendable {
    let keyId: String
    let appKey: String
    let bucket: String
    let endpoint: String
    let region: String
}

func b2ConfigFromEnv() throws -> B2Config {
    let env = ProcessInfo.processInfo.environment
    guard
        let keyId = env["B2_KEY_ID"],
        let appKey = env["B2_APPLICATION_KEY"],
        let bucket = env["B2_BUCKET"],
        let endpoint = env["B2_S3_ENDPOINT"]
    else {
        throw PhobatoError(
            "missing one of B2_KEY_ID, B2_APPLICATION_KEY, B2_BUCKET, B2_S3_ENDPOINT"
        )
    }
    let region = env["B2_REGION"] ?? endpointRegion(endpoint) ?? "us-west-002"
    return B2Config(
        keyId: keyId, appKey: appKey, bucket: bucket, endpoint: endpoint, region: region
    )
}

func endpointRegion(_ endpoint: String) -> String? {
    // e.g. https://s3.us-west-002.backblazeb2.com -> us-west-002
    guard let host = URL(string: endpoint)?.host else { return nil }
    let parts = host.split(separator: ".")
    return parts.count >= 2 ? String(parts[1]) : nil
}

func fetchBucketObjects(
    config: B2Config,
    reporter: ProgressReporter,
    debugCSVPath: String? = nil
) async throws -> [BucketObject] {
    let client = AWSClient(
        credentialProvider: .static(accessKeyId: config.keyId, secretAccessKey: config.appKey)
    )

    do {
        let result = try await listAllObjects(
            client: client, config: config, reporter: reporter, debugCSVPath: debugCSVPath
        )
        try await client.shutdown()
        return result
    } catch {
        try? await client.shutdown()
        throw error
    }
}

private func listAllObjects(
    client: AWSClient,
    config: B2Config,
    reporter: ProgressReporter,
    debugCSVPath: String?
) async throws -> [BucketObject] {
    let s3 = S3(
        client: client,
        region: Region(rawValue: config.region),
        endpoint: config.endpoint
    )

    let debugHandle = try debugCSVPath.map {
        try openCSV(at: $0, header: "key,size,last_modified")
    }
    defer { try? debugHandle?.close() }

    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime]

    var result: [BucketObject] = []
    var pageNumber = 0

    let paginator = s3.listObjectsV2Paginator(.init(bucket: config.bucket))
    for try await page in paginator {
        pageNumber += 1
        for object in page.contents ?? [] {
            guard let key = object.key,
                  let size = object.size,
                  let lastModified = object.lastModified
            else { continue }
            let bo = BucketObject(key: key, size: size, lastModified: lastModified)
            result.append(bo)
            if let h = debugHandle {
                h.write(Data(csvRow(bo, isoFormatter: isoFormatter).utf8))
            }
        }
        await reporter.recordBucket(page: pageNumber, objectCount: result.count)
    }
    await reporter.finishBucket()

    return result
}
