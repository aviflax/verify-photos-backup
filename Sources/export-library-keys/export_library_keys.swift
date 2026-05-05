import Foundation
import Photos

@main
struct ExportLibraryKeys {
    static func main() async {
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

        let limit = min(20, assets.count)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"

        for i in 0..<limit {
            let asset = assets.object(at: i)
            guard let date = asset.creationDate else {
                FileHandle.standardError.write(Data(
                    "asset \(asset.localIdentifier) has no creationDate; skipping\n".utf8
                ))
                continue
            }
            let datePath = formatter.string(from: date)
            let idPart = asset.localIdentifier.replacingOccurrences(of: "/", with: "_")
            let resources = PHAssetResource.assetResources(for: asset)
            let filename = resources.first?.originalFilename ?? ""
            let ext = (filename as NSString).pathExtension.lowercased()
            print("\(datePath)/\(idPart).\(ext)")
        }
    }
}
