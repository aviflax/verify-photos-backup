import Foundation

@main
struct VerifyBackup {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let libraryPath = args.first ?? "library-assets.csv"
        let bucketPath = args.count > 1 ? args[1] : "bucket-objects.csv"
        let matchedPath = "matched.csv"
        let notFoundPath = "not-found.csv"

        let libraryRows = try readCSV(at: libraryPath)
        let bucketRows = try readCSV(at: bucketPath)

        guard libraryRows.first == ["creation_date", "original_filename", "size"] else {
            FileHandle.standardError.write(Data(
                "library CSV header unexpected: \(libraryRows.first ?? [])\n".utf8
            ))
            exit(1)
        }
        guard bucketRows.first == ["key", "size", "last_modified"] else {
            FileHandle.standardError.write(Data(
                "bucket CSV header unexpected: \(bucketRows.first ?? [])\n".utf8
            ))
            exit(1)
        }

        let assetCount = libraryRows.count - 1
        let objectCount = bucketRows.count - 1

        let nf = NumberFormatter()
        nf.numberStyle = .decimal

        FileHandle.standardError.write(Data(
            "Loaded \(nf.string(for: assetCount) ?? "\(assetCount)") library assets and \(nf.string(for: objectCount) ?? "\(objectCount)") bucket objects.\n".utf8
        ))

        // Build bucket index: "YYYY/MM/DD|size" -> [(key, last_modified)]
        var bucketIndex: [String: [(key: String, lastModified: String)]] = [:]
        for row in bucketRows.dropFirst() {
            guard row.count >= 3 else { continue }
            let key = row[0]
            let size = row[1]
            let lastModified = row[2]
            let datePrefix = String(key.prefix(10))
            let lookupKey = "\(datePrefix)|\(size)"
            bucketIndex[lookupKey, default: []].append((key, lastModified))
        }

        FileManager.default.createFile(atPath: matchedPath, contents: nil)
        FileManager.default.createFile(atPath: notFoundPath, contents: nil)
        guard let matchedHandle = FileHandle(forWritingAtPath: matchedPath),
              let notFoundHandle = FileHandle(forWritingAtPath: notFoundPath)
        else {
            FileHandle.standardError.write(Data("cannot open output files for writing\n".utf8))
            exit(1)
        }
        defer {
            try? matchedHandle.close()
            try? notFoundHandle.close()
        }

        matchedHandle.write(Data(
            "creation_date,original_filename,size,bucket_key,bucket_last_modified\n".utf8
        ))
        notFoundHandle.write(Data("creation_date,original_filename,size\n".utf8))

        let isoParser = ISO8601DateFormatter()
        isoParser.formatOptions = [.withInternetDateTime]
        let datePrefixFormatter = DateFormatter()
        datePrefixFormatter.dateFormat = "yyyy/MM/dd"
        // datePrefixFormatter uses TimeZone.current — assumes the bucket key
        // prefixes were generated in this device's local timezone.

        var matchedCount = 0
        var notFoundCount = 0

        for row in libraryRows.dropFirst() {
            defer {
                let processed = matchedCount + notFoundCount
                if processed % 100 == 0 && processed > 0 {
                    let processedStr = nf.string(for: processed) ?? "\(processed)"
                    let totalStr = nf.string(for: assetCount) ?? "\(assetCount)"
                    let matchedStr = nf.string(for: matchedCount) ?? "\(matchedCount)"
                    let notFoundStr = nf.string(for: notFoundCount) ?? "\(notFoundCount)"
                    let percent = assetCount > 0 ? processed * 100 / assetCount : 0
                    FileHandle.standardError.write(Data(
                        "\r\u{1B}[2K\(processedStr) of \(totalStr) assets (\(percent)%) — \(matchedStr) matched, \(notFoundStr) not found".utf8
                    ))
                }
            }
            guard row.count >= 3 else { continue }
            let creationDate = row[0]
            let filename = row[1]
            let size = row[2]

            guard let date = isoParser.date(from: creationDate) else {
                FileHandle.standardError.write(Data(
                    "could not parse \(creationDate); writing to not-found\n".utf8
                ))
                notFoundHandle.write(Data(
                    "\(creationDate),\(csvField(filename)),\(size)\n".utf8
                ))
                notFoundCount += 1
                continue
            }
            let datePrefix = datePrefixFormatter.string(from: date)
            let lookupKey = "\(datePrefix)|\(size)"

            if var entries = bucketIndex[lookupKey], !entries.isEmpty {
                let matched = entries.removeFirst()
                bucketIndex[lookupKey] = entries
                matchedHandle.write(Data(
                    "\(creationDate),\(csvField(filename)),\(size),\(csvField(matched.key)),\(matched.lastModified)\n".utf8
                ))
                matchedCount += 1
            } else {
                notFoundHandle.write(Data(
                    "\(creationDate),\(csvField(filename)),\(size)\n".utf8
                ))
                notFoundCount += 1
            }
        }

        FileHandle.standardError.write(Data("\n".utf8))

        let total = matchedCount + notFoundCount
        let matchedStr = nf.string(for: matchedCount) ?? "\(matchedCount)"
        let totalStr = nf.string(for: total) ?? "\(total)"
        let notFoundStr = nf.string(for: notFoundCount) ?? "\(notFoundCount)"
        print("Matched \(matchedStr) of \(totalStr) assets; \(notFoundStr) not found.")
        print("Wrote: \(matchedPath), \(notFoundPath)")
    }
}

private func readCSV(at path: String) throws -> [[String]] {
    let contents = try String(contentsOfFile: path, encoding: .utf8)
    let lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    return lines.map(parseCSVLine)
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
                    i = next
                } else {
                    inQuotes = false
                }
            } else {
                current.append(c)
            }
        } else {
            if c == "," {
                fields.append(current)
                current = ""
            } else if c == "\"" && current.isEmpty {
                inQuotes = true
            } else {
                current.append(c)
            }
        }
        i = line.index(after: i)
    }
    fields.append(current)
    return fields
}

private func csvField(_ s: String) -> String {
    if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
        return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    return s
}
