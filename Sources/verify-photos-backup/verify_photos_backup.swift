import Foundation
import SotoS3

@main
struct VerifyPhotosBackup {
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
        let outputPath = CommandLine.arguments.dropFirst().first ?? "keys.txt"

        let client = AWSClient(
            credentialProvider: .static(accessKeyId: keyId, secretAccessKey: appKey)
        )
        defer { try? client.syncShutdown() }

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

        var count = 0
        let paginator = s3.listObjectsV2Paginator(.init(bucket: bucket))
        for try await page in paginator {
            for object in page.contents ?? [] {
                guard let key = object.key else { continue }
                handle.write(Data((key + "\n").utf8))
                count += 1
            }
        }

        print("wrote \(count) keys to \(outputPath)")
    }
}

private func endpointRegion(_ endpoint: String) -> String? {
    // e.g. https://s3.us-west-002.backblazeb2.com -> us-west-002
    guard let host = URL(string: endpoint)?.host else { return nil }
    let parts = host.split(separator: ".")
    return parts.count >= 2 ? String(parts[1]) : nil
}
