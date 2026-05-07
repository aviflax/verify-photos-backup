import Foundation

// MARK: Progress reporting
//
// Why an actor that renders on every update (Option 1):
//
// Both fetchers run concurrently and emit progress signals at independent
// rates (network-bound, page-by-page for B2; in-memory enumeration for
// PhotoKit). Writing those signals to stderr directly produces interleaved,
// noisy output. This actor unifies them: each fetcher reports its latest
// state to the actor, which serializes updates and rewrites a single
// progress line on every change.
//
// We picked this over a producer/consumer split (an AsyncStream of progress
// events feeding a dedicated renderer task) because:
//
//   - Update rates are low (a few per second total), so render-on-update
//     never over-renders.
//   - The wiring is minimal: producers replace direct stderr writes with
//     `await reporter.recordBucket(...)` / `recordLibrary(...)`.
//
// Consider migrating to the AsyncStream + renderer-task design (Option 2)
// if any of these become true:
//
//   - We want multiple sinks for progress events (e.g. a structured JSON
//     log alongside the TTY line).
//   - A producer starts firing much faster than we can render and we need
//     to throttle or coalesce — easier in a dedicated renderer task than in
//     a per-update render path.
//   - We want producers to emit progress synchronously, without `await`-ing
//     the reporter on every update; `AsyncStream.Continuation.yield(_:)` is
//     non-suspending.
//
// In that migration, this actor's state becomes the renderer task's local
// state, the fetchers accept `(Event) -> Void` closures that call
// `continuation.yield(...)`, and the orchestrator owns the renderer task
// lifecycle (spawn, await done, tear down).

actor ProgressReporter {
    private var bucket: BucketProgress?
    private var library: LibraryProgress?
    private var finished = false

    private let nf: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    func recordBucket(page: Int, objectCount: Int) {
        bucket = BucketProgress(page: page, objectCount: objectCount)
        render()
    }

    func recordLibrary(processed: Int, total: Int) {
        library = LibraryProgress(processed: processed, total: total)
        render()
    }

    func finish() {
        guard !finished else { return }
        FileHandle.standardError.write(Data("\n".utf8))
        finished = true
    }

    private func render() {
        guard !finished else { return }
        var parts: [String] = []
        if let b = bucket {
            parts.append(
                "[ bucket: page \(b.page) — \(fmt(b.objectCount)) objects so far ]"
            )
        }
        if let l = library {
            let percent = l.total > 0 ? l.processed * 100 / l.total : 0
            parts.append(
                "[ library: \(percent)% (\(fmt(l.processed)) / \(fmt(l.total))) ]"
            )
        }
        guard !parts.isEmpty else { return }
        let line = "Scanning: " + parts.joined(separator: "   ")
        FileHandle.standardError.write(Data("\r\u{1B}[2K\(line)".utf8))
    }

    private func fmt(_ n: Int) -> String { nf.string(for: n) ?? "\(n)" }
}

private struct BucketProgress {
    let page: Int
    let objectCount: Int
}

private struct LibraryProgress {
    let processed: Int
    let total: Int
}
