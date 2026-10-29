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

    @Test func openEndedRequestKeepsTheRangeOpen() throws {
        let url = try #require(URL(string: "https://immich.example/video"))
        let configuration = AuthenticatedVideoStreamConfiguration(
            assetID: "video",
            url: url,
            authorization: "Bearer secret"
        )

        let request = AuthenticatedVideoStreamSource.request(
            configuration: configuration,
            range: 4096 ..< Int64.max,
            requestsToEnd: true
        )

        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=4096-")
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
