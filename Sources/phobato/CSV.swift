import Foundation

func csvField(_ s: String) -> String {
    if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
        return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    return s
}

func csvRow(_ obj: BucketObject, isoFormatter: ISO8601DateFormatter) -> String {
    "\(csvField(obj.key)),\(obj.size),\(isoFormatter.string(from: obj.lastModified))\n"
}

func csvRow(_ asset: LibraryAsset, isoFormatter: ISO8601DateFormatter) -> String {
    "\(isoFormatter.string(from: asset.creationDate)),\(csvField(asset.originalFilename)),\(asset.size),\(csvField(asset.localIdentifier))\n"
}

func notFoundCsvRow(_ asset: LibraryAsset, isoFormatter: ISO8601DateFormatter) -> String {
    "\(isoFormatter.string(from: asset.creationDate)),\(csvField(asset.originalFilename)),\(asset.size),\(csvField(asset.localIdentifier)),\(csvField(asset.cloudIdentifier ?? ""))\n"
}

func csvRow(_ matched: MatchedAsset, isoFormatter: ISO8601DateFormatter) -> String {
    let a = matched.asset
    let b = matched.bucketObject
    return "\(isoFormatter.string(from: a.creationDate)),\(csvField(a.originalFilename)),\(a.size),\(csvField(b.key)),\(isoFormatter.string(from: b.lastModified))\n"
}

func openCSV(at path: String, header: String) throws -> FileHandle {
    FileManager.default.createFile(atPath: path, contents: nil)
    guard let h = FileHandle(forWritingAtPath: path) else {
        throw PhobatoError("cannot open \(path) for writing")
    }
    h.write(Data("\(header)\n".utf8))
    return h
}

func writeMatchResult(_ result: MatchResult, matchedPath: String?, notFoundPath: String?) throws {
    guard matchedPath != nil || notFoundPath != nil else { return }
    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime]
    if let path = matchedPath {
        let h = try openCSV(
            at: path,
            header: "creation_date,original_filename,size,bucket_key,bucket_last_modified"
        )
        defer { try? h.close() }
        for matched in result.matched {
            h.write(Data(csvRow(matched, isoFormatter: isoFormatter).utf8))
        }
    }
    if let path = notFoundPath {
        let h = try openCSV(
            at: path,
            header: "creation_date,original_filename,size,local_id,cloud_id"
        )
        defer { try? h.close() }
        for asset in result.notFound {
            h.write(Data(notFoundCsvRow(asset, isoFormatter: isoFormatter).utf8))
        }
    }
}
