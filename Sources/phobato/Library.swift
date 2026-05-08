import Foundation
import Photos

struct LibraryAsset: Sendable {
    let creationDate: Date
    let originalFilename: String
    let size: Int64
    let localIdentifier: String
    var cloudIdentifier: String? = nil
}

private let progressBatch = 1000

func fetchLibraryAssets(
    reporter: ProgressReporter,
    debugCSVPath: String? = nil
) async throws -> [LibraryAsset] {
    let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    guard status == .authorized || status == .limited else {
        throw PhobatoError("Photos access not granted (status: \(status.rawValue))")
    }

    let options = PHFetchOptions()
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
    let assets = PHAsset.fetchAssets(with: options)
    let assetCount = assets.count

    let debugHandle = try debugCSVPath.map {
        try openCSV(at: $0, header: "creation_date,original_filename,size,local_id")
    }
    defer { try? debugHandle?.close() }

    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime]

    var result: [LibraryAsset] = []
    result.reserveCapacity(assetCount)
    var pendingProgress = 0

    for i in 0..<assetCount {
        pendingProgress += 1
        if pendingProgress >= progressBatch {
            await reporter.incrementLibrary(by: pendingProgress, total: assetCount)
            pendingProgress = 0
        }

        let asset = assets.object(at: i)
        guard let date = asset.creationDate else {
            errPrint("\n[library] asset \(asset.localIdentifier) has no creationDate; skipping\n")
            continue
        }
        let resources = PHAssetResource.assetResources(for: asset)
        var originalResource: PHAssetResource?
        for r in resources where r.type == .photo || r.type == .video {
            originalResource = r
            break
        }
        guard let resource = originalResource else {
            errPrint("\n[library] asset \(asset.localIdentifier) has no photo/video resource; skipping\n")
            continue
        }
        guard let size = resourceFileSize(resource) else {
            errPrint("\n[library] asset \(asset.localIdentifier) has no fileSize; skipping\n")
            continue
        }
        let la = LibraryAsset(
            creationDate: date,
            originalFilename: resource.originalFilename,
            size: size,
            localIdentifier: asset.localIdentifier
        )
        result.append(la)
        if let h = debugHandle {
            h.write(Data(csvRow(la, isoFormatter: isoFormatter).utf8))
        }
    }

    if pendingProgress > 0 {
        await reporter.incrementLibrary(by: pendingProgress, total: assetCount)
    }

    return result
}

/// Returns copies of `assets` with `cloudIdentifier` populated where PhotoKit
/// can resolve one. Assets without a cloud identifier (e.g. not yet uploaded
/// to iCloud, or iCloud Photos disabled) are returned with `cloudIdentifier`
/// left nil.
func populateCloudIdentifiers(for assets: [LibraryAsset]) -> [LibraryAsset] {
    guard !assets.isEmpty else { return assets }
    let mappings = PHPhotoLibrary.shared().cloudIdentifierMappings(
        forLocalIdentifiers: assets.map(\.localIdentifier)
    )
    return assets.map { asset in
        var a = asset
        if case .success(let cid) = mappings[asset.localIdentifier] {
            a.cloudIdentifier = cid.stringValue
        }
        return a
    }
}

private func resourceFileSize(_ resource: PHAssetResource) -> Int64? {
    let obj = resource as NSObject
    guard obj.responds(to: NSSelectorFromString("fileSize")),
          let n = obj.value(forKey: "fileSize") as? NSNumber
    else { return nil }
    return n.int64Value
}
