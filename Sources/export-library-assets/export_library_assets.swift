import Foundation
import Photos

@main
struct ExportLibraryAssets {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let diagnose = args.contains("--diagnose")
        let outputPath = args.first(where: { !$0.hasPrefix("--") }) ?? "library-assets.csv"

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            FileHandle.standardError.write(Data(
                "Photos access not granted (status: \(status.rawValue))\n".utf8
            ))
            exit(1)
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(with: options)

        if diagnose {
            runDiagnostic(assets: assets)
            return
        }

        FileManager.default.createFile(atPath: outputPath, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: outputPath) else {
            FileHandle.standardError.write(Data("cannot open \(outputPath) for writing\n".utf8))
            exit(1)
        }
        defer { try? handle.close() }

        handle.write(Data("creation_date,original_filename,size\n".utf8))

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        let assetCount = assets.count
        var rowCount = 0

        for i in 0..<assetCount {
            let asset = assets.object(at: i)
            guard let date = asset.creationDate else {
                FileHandle.standardError.write(Data(
                    "\nasset \(asset.localIdentifier) has no creationDate; skipping\n".utf8
                ))
                continue
            }
            let dateStr = isoFormatter.string(from: date)
            let resources = PHAssetResource.assetResources(for: asset)
            let original = resources.first(where: {
                $0.type == .originalPhoto || $0.type == .originalVideo
            }) ?? resources.first(where: {
                $0.type == .photo || $0.type == .video
            })
            guard let resource = original else {
                FileHandle.standardError.write(Data(
                    "\nasset \(asset.localIdentifier) has no photo/video resource; skipping\n".utf8
                ))
                continue
            }
            let filename = resource.originalFilename
            let size = resourceFileSize(resource)
            handle.write(Data("\(dateStr),\(csvField(filename)),\(size)\n".utf8))
            rowCount += 1

            if (i + 1) % 100 == 0 {
                let percent = (i + 1) * 100 / assetCount
                FileHandle.standardError.write(Data(
                    "\r\u{1B}[2K\(i + 1) out of \(assetCount) (\(percent)%)".utf8
                ))
            }
        }
        FileHandle.standardError.write(Data("\n".utf8))

        print("Wrote \(rowCount) rows for \(assetCount) assets to \(outputPath)")
    }
}

private func resourceFileSize(_ resource: PHAssetResource) -> String {
    let obj = resource as NSObject
    guard obj.responds(to: NSSelectorFromString("fileSize")),
          let n = obj.value(forKey: "fileSize") as? NSNumber
    else { return "" }
    return n.stringValue
}

private func csvField(_ s: String) -> String {
    if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
        return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    return s
}
