import Foundation
import SotoS3

@main
struct ExportBucketObjects {
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        guard
            let keyId = env["B2_KEY_ID"],
            let appKey = env["B2_APPLICATION_KEY"],
            let bucket = env["B2_BUCKET"],
            let endpoint = env["B2_S3_ENDPOINT"]
        else {
            FileHandle.standardError.write(Data(
                "missing one of B2_KEY_ID, B2_APPLICATION_KEY, B2_BUCKET, B2_S3_ENDPOINT\n".utf8
            ))
            exit(1)
        }

        let region = env["B2_REGION"] ?? endpointRegion(endpoint) ?? "us-west-002"
        let outputPath = CommandLine.arguments.dropFirst().first ?? "bucket-objects.csv"

        let client = AWSClient(
            credentialProvider: .static(accessKeyId: keyId, secretAccessKey: appKey)
        )

        let s3 = S3(
            client: client,
            region: Region(rawValue: region),
            endpoint: endpoint
        )

        FileManager.default.createFile(atPath: outputPath, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: outputPath) else {
            FileHandle.standardError.write(Data("cannot open \(outputPath) for writing\n".utf8))
            exit(1)
        }
        defer { try? handle.close() }

        handle.write(Data("key,size,last_modified\n".utf8))

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        var pageNumber = 0
        var count = 0

        let paginator = s3.listObjectsV2Paginator(.init(bucket: bucket))
        for try await page in paginator {
            pageNumber += 1
            print("Page \(pageNumber)...", terminator: "")

            for object in page.contents ?? [] {
                guard let key = object.key else { continue }
                let size = object.size.map(String.init) ?? ""
                let lastModified = object.lastModified.map { isoFormatter.string(from: $0) } ?? ""
                handle.write(Data("\(csvField(key)),\(size),\(lastModified)\n".utf8))
                count += 1
            }

            print("✅")
        }

        try await client.shutdown()

        print("\n\nWrote \(count) objects to \(outputPath)")
    }
}

private func endpointRegion(_ endpoint: String) -> String? {
    // e.g. https://s3.us-west-002.backblazeb2.com -> us-west-002
    guard let host = URL(string: endpoint)?.host else { return nil }
    let parts = host.split(separator: ".")
    return parts.count >= 2 ? String(parts[1]) : nil
}

private func csvField(_ s: String) -> String {
    if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
        return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    return s
}
