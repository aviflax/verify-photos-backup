import Foundation
import ObjectiveC
import Photos

func runDiagnostic(assets: PHFetchResult<PHAsset>) {
    let limit = min(1, assets.count)
    let stderr = FileHandle.standardError

    func write(_ s: String) {
        stderr.write(Data(s.utf8))
    }

    var localIDs: [String] = []
    for i in 0..<limit {
        localIDs.append(assets.object(at: i).localIdentifier)
    }
    let cloudMappings = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: localIDs)

    for i in 0..<limit {
        let asset = assets.object(at: i)
        write("\n=== Asset \(i + 1) of \(limit) ===\n")
        write("runtime class: \(NSStringFromClass(type(of: asset)))\n")
        write("localIdentifier: \(asset.localIdentifier)\n")
        switch cloudMappings[asset.localIdentifier] {
        case .success(let cloudID):
            write("cloudIdentifier: \(cloudID.stringValue)\n")
        case .failure(let error):
            write("cloudIdentifier: <error: \(error)>\n")
        case .none:
            write("cloudIdentifier: <no mapping returned>\n")
        }
        write("creationDate: \(asset.creationDate?.description ?? "nil")\n")
        write("mediaType: \(asset.mediaType.rawValue) (image=1, video=2)\n")

        let resources = PHAssetResource.assetResources(for: asset)
        write("resources: \(resources.count)\n")

        for (j, resource) in resources.enumerated() {
            write("\n  --- Resource \(j + 1) of \(resources.count) ---\n")
            write("  runtime class: \(NSStringFromClass(type(of: resource)))\n")
            write("  type: \(resource.type.rawValue) ")
            write("(photo=1, video=2, audio=3, alternatePhoto=4, fullSizePhoto=5, fullSizeVideo=6, adjustmentData=7, adjustmentBasePhoto=8, pairedVideo=9, fullSizePairedVideo=10, adjustmentBasePairedVideo=11, originalPhoto=13, originalVideo=14)\n")
            write("  originalFilename: \(resource.originalFilename)\n")
            write("  uniformTypeIdentifier: \(resource.uniformTypeIdentifier)\n")
            write("  assetLocalIdentifier: \(resource.assetLocalIdentifier)\n")

            write("\n  -- @property names walked up class hierarchy --\n")
            dumpProperties(of: resource as NSObject, write: write)

            write("\n  -- candidate KVC keys --\n")
            let candidates = [
                "uuid", "_uuid",
                "version", "versionString",
                "recipeID", "recipeId",
                "originalUUID", "originalResourceUUID",
                "fileURL", "privateFileURL",
                "fileSize", "filesize",
                "isCurrent", "isLocallyAvailable", "isOriginal",
                "cloudIdentifier", "cloudResourceIdentifier",
                "trashedDate",
            ]
            for key in candidates {
                let obj = resource as NSObject
                if obj.responds(to: NSSelectorFromString(key)) {
                    let val = obj.value(forKey: key)
                    write("  [responds] \(key) = \(String(describing: val))\n")
                }
            }
        }
    }
    write("\n")
}

private func dumpProperties(of obj: NSObject, write: (String) -> Void) {
    var cls: AnyClass? = type(of: obj)
    while let c = cls, c != NSObject.self {
        var count: UInt32 = 0
        guard let props = class_copyPropertyList(c, &count) else {
            cls = class_getSuperclass(c)
            continue
        }
        if count > 0 {
            write("  class \(NSStringFromClass(c)):\n")
            for k in 0..<Int(count) {
                let name = String(cString: property_getName(props[k]))
                if obj.responds(to: NSSelectorFromString(name)) {
                    let val = obj.value(forKey: name)
                    write("    \(name) = \(String(describing: val))\n")
                } else {
                    write("    \(name) = <not responding to selector>\n")
                }
            }
        }
        free(props)
        cls = class_getSuperclass(c)
    }
}
