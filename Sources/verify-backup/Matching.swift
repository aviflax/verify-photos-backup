import Foundation

struct MatchedAsset: Sendable {
    let asset: LibraryAsset
    let bucketObject: BucketObject
}

struct MatchResult: Sendable {
    let matched: [MatchedAsset]
    let notFound: [LibraryAsset]
}

private struct LookupKey: Hashable {
    let datePrefix: String
    let size: Int64
}

typealias MatchProgress = (
    _ processed: Int, _ total: Int, _ matched: Int, _ notFound: Int
) -> Void

func match(
    assets: [LibraryAsset],
    objects: [BucketObject],
    timezone: TimeZone = .current,
    progress: MatchProgress? = nil
) -> MatchResult {
    var index: [LookupKey: [BucketObject]] = [:]
    for obj in objects {
        // Bucket keys begin with "YYYY/MM/DD/..."; the first 10 chars are the date.
        let datePrefix = String(obj.key.prefix(10))
        let key = LookupKey(datePrefix: datePrefix, size: obj.size)
        index[key, default: []].append(obj)
    }

    let datePrefixFormatter = DateFormatter()
    datePrefixFormatter.dateFormat = "yyyy/MM/dd"
    datePrefixFormatter.timeZone = timezone

    var matched: [MatchedAsset] = []
    var notFound: [LibraryAsset] = []
    matched.reserveCapacity(assets.count)

    for (i, asset) in assets.enumerated() {
        let datePrefix = datePrefixFormatter.string(from: asset.creationDate)
        let key = LookupKey(datePrefix: datePrefix, size: asset.size)
        if var entries = index[key], !entries.isEmpty {
            let bo = entries.removeFirst()
            index[key] = entries
            matched.append(MatchedAsset(asset: asset, bucketObject: bo))
        } else {
            notFound.append(asset)
        }
        let processed = i + 1
        if processed % 100 == 0 || processed == assets.count {
            progress?(processed, assets.count, matched.count, notFound.count)
        }
    }

    return MatchResult(matched: matched, notFound: notFound)
}
