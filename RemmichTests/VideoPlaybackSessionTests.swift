import AVFoundation
import Testing
@testable import Remmich

struct VideoPlaybackSessionTests {
    @Test func bufferedSecondsUsesTheRangeContainingThePlayhead() {
        let first = CMTimeRange(
            start: CMTime(seconds: 0, preferredTimescale: 600),
            duration: CMTime(seconds: 5, preferredTimescale: 600)
        )
        let active = CMTimeRange(
            start: CMTime(seconds: 10, preferredTimescale: 600),
            duration: CMTime(seconds: 12, preferredTimescale: 600)
        )

        let seconds = VideoPlaybackSession.bufferedSecondsAhead(
            timeRanges: [NSValue(timeRange: first), NSValue(timeRange: active)],
            currentSeconds: 14
        )

        #expect(abs(seconds - 8) < 0.001)
    }

    @Test func bufferedSecondsIsZeroOutsideLoadedRanges() {
        let range = CMTimeRange(
            start: CMTime(seconds: 10, preferredTimescale: 600),
            duration: CMTime(seconds: 5, preferredTimescale: 600)
        )

        #expect(VideoPlaybackSession.bufferedSecondsAhead(
            timeRanges: [NSValue(timeRange: range)],
            currentSeconds: 3
        ) == 0)
    }

    @Test func transportFailuresKeepTheirUserRelevantCategory() {
        #expect(VideoPlaybackSession.normalizedFailure(
            for: AuthenticatedVideoStreamError.unauthorized
        ) == .authentication)
        #expect(VideoPlaybackSession.normalizedFailure(
            for: AuthenticatedVideoStreamError.invalidRange
        ) == .invalidRange)
        #expect(VideoPlaybackSession.normalizedFailure(
            for: AuthenticatedVideoStreamError.network(retryable: true)
        ) == .network(retryable: true))
        #expect(VideoPlaybackSession.normalizedFailure(
            for: AuthenticatedVideoStreamError.cancelled
        ) == nil)
    }

    @Test func nativePlaybackErrorsSeparateDecoderAndConnectivityFailures() {
        let decoder = NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.decoderNotFound.rawValue
        )
        let offline = NSError(
            domain: NSURLErrorDomain,
            code: URLError.notConnectedToInternet.rawValue
        )

        #expect(VideoPlaybackSession.normalizedFailure(for: decoder) == .unsupportedMedia)
        #expect(VideoPlaybackSession.normalizedFailure(for: offline) == .network(retryable: true))
    }
}
