import Foundation
import MazidiFoundations
import Testing
@testable import MazidiContent

@Suite struct MediaFetchingTests {
    private let squat: ExerciseSlug = "barbell-squat"
    private let origin = RemoteMediaOrigin(baseURL: URL(string: "https://cdn.example")!)

    private func locator(version: Int = 1, kind: MediaKind = .poster, bytes: Int = 4) -> MediaLocator {
        MediaLocator(
            id: MediaAssetID(slug: squat, kind: kind, contentVersion: version),
            checksum: MediaChecksum(sha256: "abc", bytes: bytes)
        )
    }

    // A fetcher that counts invocations, to prove no internal retry loop.
    private actor CountingFetcher: MediaFetching {
        let inner: DeterministicMediaFetcher
        private(set) var calls = 0
        init(_ inner: DeterministicMediaFetcher) { self.inner = inner }
        func fetch(_ locator: MediaLocator, from origin: RemoteMediaOrigin) async -> Result<Data, MediaFetchError> {
            calls += 1
            return await inner.fetch(locator, from: origin)
        }
    }

    // MARK: - Typed outcomes from the deterministic fake

    @Test func validHitReturnsBytes() async throws {
        let loc = locator()
        let fetcher = DeterministicMediaFetcher(bytesByObjectKey: [loc.objectKey: Data("webp".utf8)])
        let result = await fetcher.fetch(loc, from: origin)
        #expect(try result.get() == Data("webp".utf8))
    }

    @Test func unknownKeyIsNotFound() async {
        let fetcher = DeterministicMediaFetcher()
        let result = await fetcher.fetch(locator(), from: origin)
        #expect(result == .failure(.notFound))
    }

    @Test func configuredFailuresPropagateTyped() async {
        let loc = locator()
        for expected: MediaFetchError in [.unreachable, .checksumMismatch, .decode, .notFound] {
            let fetcher = DeterministicMediaFetcher(failuresByObjectKey: [loc.objectKey: expected])
            let result = await fetcher.fetch(loc, from: origin)
            #expect(result == .failure(expected))
        }
    }

    @Test func cancelledTaskYieldsCancelled() async {
        let loc = locator()
        let fetcher = DeterministicMediaFetcher(bytesByObjectKey: [loc.objectKey: Data("webp".utf8)])
        let task = Task { await fetcher.fetch(loc, from: origin) }
        task.cancel()
        let result = await task.value
        #expect(result == .failure(.cancelled))
    }

    // MARK: - No retry loop

    @Test func coordinatorDoesNotRetryOnFailure() async {
        let loc = locator()
        let counting = CountingFetcher(DeterministicMediaFetcher(failuresByObjectKey: [loc.objectKey: .unreachable]))
        let coordinator = MediaRequestCoordinator(fetcher: counting)
        let result = await coordinator.fetch(loc, from: origin)
        #expect(result == .failure(.unreachable))
        #expect(await counting.calls == 1)   // exactly once — no hot loop
    }

    // MARK: - Stale-request / version protection

    @Test func supersededVersionIsDiscarded() async {
        let v1 = locator(version: 1)
        let v2 = locator(version: 2)
        let fetcher = DeterministicMediaFetcher(bytesByObjectKey: [
            v1.objectKey: Data("v1".utf8),
            v2.objectKey: Data("v2".utf8),
        ])
        let coordinator = MediaRequestCoordinator(fetcher: fetcher)
        // A newer version (v2) is requested first, then a late v1 fetch completes.
        _ = await coordinator.fetch(v2, from: origin)
        let staleResult = await coordinator.fetch(v1, from: origin)
        #expect(staleResult == .failure(.cancelled))   // v1 superseded by v2
    }

    @Test func currentVersionIsNotTreatedAsStale() async {
        let v2 = locator(version: 2)
        let fetcher = DeterministicMediaFetcher(bytesByObjectKey: [v2.objectKey: Data("v2".utf8)])
        let coordinator = MediaRequestCoordinator(fetcher: fetcher)
        let result = await coordinator.fetch(v2, from: origin)
        #expect((try? result.get()) == Data("v2".utf8))
    }

    @Test func differentSurfacesDoNotSupersedeEachOther() async {
        // Poster and video for the same slug are independent surfaces (ADR-0010 §7).
        let poster = locator(version: 3, kind: .poster)
        let video = locator(version: 1, kind: .video)
        let fetcher = DeterministicMediaFetcher(bytesByObjectKey: [
            poster.objectKey: Data("p".utf8),
            video.objectKey: Data("v".utf8),
        ])
        let coordinator = MediaRequestCoordinator(fetcher: fetcher)
        _ = await coordinator.fetch(poster, from: origin)
        let videoResult = await coordinator.fetch(video, from: origin)
        #expect((try? videoResult.get()) == Data("v".utf8))   // video not superseded by poster v3
    }
}
