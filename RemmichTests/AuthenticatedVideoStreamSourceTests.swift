import AVFoundation
import Foundation
import Testing
@testable import Remmich

struct AuthenticatedVideoStreamSourceTests {
    @Test func rangeRequestKeepsAuthenticationOutOfTheURL() throws {
        let url = try #require(URL(string: "https://immich.example/api/assets/video/video/playback"))
        let configuration = AuthenticatedVideoStreamConfiguration(
            assetID: "video",
            url: url,
            authorization: "Bearer secret"
        )

        let request = AuthenticatedVideoStreamSource.request(
            configuration: configuration,
            range: 1024 ..< 2048
        )

        #expect(request.url == url)
        #expect(request.url?.absoluteString.contains("secret") == false)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=1024-2047")
        #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
    }

    @Test func contentRangeProvidesTheWholePlaybackLength() throws {
        let url = try #require(URL(string: "https://immich.example/video"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Range": "bytes 1024-2047/42800000",
                "Content-Length": "1024",
            ]
        ))

        #expect(AuthenticatedVideoStreamSource.totalLength(response: response) == 42_800_000)
    }

    @Test func eofRequestRemainsOpenAcrossBoundedHTTPChunks() {
        var progress = VideoStreamRequestProgress(requestedRange: 4096 ..< Int64.max)
        #expect(progress.beginChunk(maxBytes: 1024) == 4096 ..< 5120)
        progress.configure(.init(contentLength: 5500, responseRange: 4096 ..< 5120, expectedByteCount: 1024))
        #expect(progress.consume(byteCount: 2048) == 1024)
        #expect(progress.chunkComplete)
        #expect(!progress.requestComplete)
        #expect(progress.beginChunk(maxBytes: 1024) == 5120 ..< 5500)
        progress.configure(.init(contentLength: 5500, responseRange: 5120 ..< 5500, expectedByteCount: 380))
        #expect(progress.consume(byteCount: 380) == 380)
        #expect(progress.requestComplete)
        #expect(progress.beginChunk(maxBytes: 1024) == nil)
    }

    @Test func finiteRequestCompletesAtItsOwnEndWithoutReadingToEOF() {
        var progress = VideoStreamRequestProgress(requestedRange: 100 ..< 300)
        #expect(progress.beginChunk(maxBytes: 128) == 100 ..< 228)
        progress.configure(.init(contentLength: 1000, responseRange: 100 ..< 228, expectedByteCount: 128))
        #expect(progress.consume(byteCount: 128) == 128)
        #expect(!progress.requestComplete)
        #expect(progress.beginChunk(maxBytes: 128) == 228 ..< 300)
        progress.configure(.init(contentLength: 1000, responseRange: 228 ..< 300, expectedByteCount: 72))
        #expect(progress.consume(byteCount: 72) == 72)
        #expect(progress.requestComplete)
    }

    @Test func bufferPacingUsesTimeWithHysteresis() {
        var policy = VideoStreamBufferPolicy()
        policy.update(duration: 300, ahead: 11)
        #expect(policy.isThrottled)
        policy.update(duration: 300, ahead: 8)
        #expect(policy.isThrottled)
        policy.update(duration: 300, ahead: 5)
        #expect(!policy.isThrottled)
        policy.update(duration: 300, ahead: 9)
        #expect(!policy.isThrottled)
        policy.update(duration: 300, ahead: 10)
        #expect(policy.isThrottled)
    }

    @Test func chunkBudgetScalesWithWholeFileBitrateAndRemainingHeadroom() {
        var policy = VideoStreamBufferPolicy()
        policy.update(duration: 100, ahead: 0)
        #expect(policy.chunkBytes(contentLength: 10_000_000) == 200_000)
        #expect(policy.chunkBytes(contentLength: 20_000_000) == 400_000)
        policy.update(duration: 100, ahead: 9)
        #expect(policy.chunkBytes(contentLength: 20_000_000) == 200_000)
        policy.update(duration: .nan, ahead: 0)
        #expect(policy.chunkBytes(contentLength: 20_000_000) == 65536)
        policy.update(duration: 1, ahead: 0)
        #expect(policy.chunkBytes(contentLength: Int64.max) == 2_097_152)
    }

    @Test func lowBitrateStillSizesReadsFromTimeInsteadOfAFixedMinimum() {
        var policy = VideoStreamBufferPolicy()
        policy.update(duration: 1000, ahead: 0)
        #expect(policy.chunkBytes(contentLength: 10000) == 20)
    }

    @Test(arguments: ["video-fast-start", "video-tail-moov"])
    func loadsMP4MetadataAcrossBoundedRequests(fixture: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VideoFixtureProtocol.self]
        let source = try AuthenticatedVideoStreamSource(
            configuration: .init(assetID: "fixture", url: #require(URL(string: "https://video-fixture.invalid/\(fixture).mp4")), authorization: "Bearer fixture"),
            sessionConfiguration: configuration
        )
        defer { source.invalidate() }
        let seconds = try await withThrowingTaskGroup(of: Double.self) { group in
            group.addTask { try await source.asset.load(.duration).seconds }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                source.asset.cancelLoading()
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await #require(group.next())
        }
        #expect(abs(seconds - 2) < 0.1)
    }

    @Test func partialResponseMustBeginAtTheRequestedOffset() throws {
        let url = try #require(URL(string: "https://immich.example/video"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Range": "bytes 1024-2047/42800000",
                "Content-Length": "1024",
            ]
        ))

        let plan = try AuthenticatedVideoStreamSource.responsePlan(
            response: response,
            requestedOffset: 1024,
            requestedLength: 512,
            requestsToEnd: false
        )
        #expect(plan == AuthenticatedVideoResponsePlan(
            contentLength: 42_800_000,
            responseRange: 1024 ..< 2048,
            expectedByteCount: 512
        ))

        #expect(throws: AuthenticatedVideoStreamError.invalidRange) {
            try AuthenticatedVideoStreamSource.responsePlan(
                response: response,
                requestedOffset: 2048,
                requestedLength: 512,
                requestsToEnd: false
            )
        }
    }

    @Test func rangeFailureStatusesAreClassifiedBeforePlayback() throws {
        let url = try #require(URL(string: "https://immich.example/video"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 416,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))

        #expect(throws: AuthenticatedVideoStreamError.invalidRange) {
            try AuthenticatedVideoStreamSource.responsePlan(
                response: response,
                requestedOffset: 1000,
                requestedLength: 512,
                requestsToEnd: false
            )
        }
    }
}

/// Local fixtures exercise AVFoundation's real request/cancel lifecycle without a server.
private final nonisolated class VideoFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "video-fixture.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let name = request.url!.deletingPathExtension().lastPathComponent
            let bundle = Bundle(for: VideoFixtureProtocol.self)
            guard let url = bundle.url(forResource: name, withExtension: "mp4")
                ?? bundle.url(forResource: name, withExtension: "mp4", subdirectory: "Fixtures") else { throw URLError(.fileDoesNotExist) }
            let data = try Data(contentsOf: url)
            let fields = (request.value(forHTTPHeaderField: "Range") ?? "").dropFirst(6).split(separator: "-")
            guard fields.count == 2, let start = Int(fields[0]), let last = Int(fields[1]), start < data.count else { throw URLError(.badServerResponse) }
            let end = min(data.count, last + 1)
            let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Range": "bytes \(start)-\(end - 1)/\(data.count)",
                "Content-Length": "\(end - start)", "Content-Type": "video/mp4", "Accept-Ranges": "bytes",
            ])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data.subdata(in: start ..< end))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() {}
}
