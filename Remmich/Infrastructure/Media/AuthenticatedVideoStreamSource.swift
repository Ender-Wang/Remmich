import AVFoundation
import Foundation
import OSLog
import UniformTypeIdentifiers

nonisolated struct AuthenticatedVideoStreamConfiguration: Sendable {
    let assetID: String
    let url: URL
    let authorization: String
}

nonisolated enum AuthenticatedVideoStreamError: LocalizedError, Equatable {
    case invalidRequest
    case invalidResponse
    case invalidRange
    case unauthorized
    case unavailable(statusCode: Int)
    case network(retryable: Bool)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "The video request could not be created."
        case .invalidResponse:
            "The video server returned an invalid response."
        case .invalidRange:
            "The video server returned an invalid byte range."
        case .unauthorized:
            "The video session is no longer authorized."
        case let .unavailable(statusCode):
            "The video server returned status \(statusCode)."
        case .network:
            "The video stream was interrupted."
        case .cancelled:
            "Video streaming was cancelled."
        }
    }
}

nonisolated struct AuthenticatedVideoResponsePlan: Equatable {
    let contentLength: Int64?
    let responseRange: Range<Int64>?
    let expectedByteCount: Int64?
}

/// The time window is authoritative; average byte rate only sizes individual reads.
nonisolated struct VideoStreamBufferPolicy {
    static let targetSeconds = 10.0
    static let resumeSeconds = 5.0
    var durationSeconds = 0.0
    private(set) var secondsAhead = 0.0
    private(set) var isThrottled = false

    mutating func update(duration: Double, ahead: Double) {
        durationSeconds = duration.isFinite && duration > 0 ? duration : 0
        secondsAhead = ahead.isFinite ? max(0, ahead) : 0
        if secondsAhead >= Self.targetSeconds {
            isThrottled = true
        } else if secondsAhead <= Self.resumeSeconds {
            isThrottled = false
        }
    }

    func chunkBytes(contentLength: Int64?) -> Int64 {
        guard let contentLength, contentLength > 0, durationSeconds > 0 else { return 65536 }
        let seconds = min(2, max(0.25, Self.targetSeconds - secondsAhead))
        let estimate = Double(contentLength) / durationSeconds * seconds
        return Int64(min(2_097_152, max(1, estimate.rounded(.up))))
    }
}

/// Tracks the AVFoundation request independently from its HTTP subrequests.
nonisolated struct VideoStreamRequestProgress {
    let requestedRange: Range<Int64>
    private(set) var offset: Int64
    private var resourceEnd: Int64?
    private(set) var chunkRange: Range<Int64> = 0 ..< 0
    private var chunkExpectedBytes: Int64 = 0
    private var chunkDeliveredBytes: Int64 = 0

    init(requestedRange: Range<Int64>) {
        self.requestedRange = requestedRange
        offset = requestedRange.lowerBound
    }

    mutating func beginChunk(maxBytes: Int64) -> Range<Int64>? {
        let end = min(requestedRange.upperBound, resourceEnd ?? Int64.max)
        guard offset < end, maxBytes > 0 else { return nil }
        let length = min(maxBytes, end - offset)
        chunkRange = offset ..< (offset + length)
        chunkExpectedBytes = length
        chunkDeliveredBytes = 0
        return chunkRange
    }

    mutating func configure(_ plan: AuthenticatedVideoResponsePlan) {
        resourceEnd = plan.contentLength
        chunkExpectedBytes = plan.expectedByteCount ?? 0
    }

    var chunkComplete: Bool {
        chunkDeliveredBytes >= chunkExpectedBytes
    }

    var requestComplete: Bool {
        offset >= min(requestedRange.upperBound, resourceEnd ?? Int64.max)
    }

    mutating func consume(byteCount: Int64) -> Int64 {
        let count = min(max(0, byteCount), max(0, chunkExpectedBytes - chunkDeliveredBytes))
        offset += count
        chunkDeliveredBytes += count
        return count
    }
}

final nonisolated class AuthenticatedVideoStreamSource: NSObject, @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "io.github.ender-wang.Remmich",
        category: "VideoStream"
    )
    private static let scheme = "remmich-video"

    let assetID: String
    let asset: AVURLAsset

    private let configuration: AuthenticatedVideoStreamConfiguration
    private let contentLengthChanged: @Sendable (Int64) -> Void
    private let delegateQueue: DispatchQueue
    private let operationQueue: OperationQueue
    private var session: URLSession!
    private let lock = NSLock()
    private var contextsByTaskID: [Int: RequestContext] = [:]
    private var loadingContexts: [ObjectIdentifier: RequestContext] = [:]
    private var nextRequestSequence = 0
    private var contentLength: Int64?
    private var bufferPolicy = VideoStreamBufferPolicy()
    private var pumpScheduled = false
    private var taskIDByLoadingRequest: [ObjectIdentifier: Int] = [:]
    private var isInvalidated = false
    private var startedRequestCount = 0
    private var deliveredByteCount: Int64 = 0

    init(
        configuration: AuthenticatedVideoStreamConfiguration,
        contentLengthChanged: @escaping @Sendable (Int64) -> Void = { _ in },
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) throws {
        guard var components = URLComponents(
            url: configuration.url,
            resolvingAgainstBaseURL: false
        ) else {
            throw AuthenticatedVideoStreamError.invalidRequest
        }
        components.scheme = Self.scheme
        guard let assetURL = components.url else {
            throw AuthenticatedVideoStreamError.invalidRequest
        }

        self.configuration = configuration
        self.contentLengthChanged = contentLengthChanged
        assetID = configuration.assetID
        delegateQueue = DispatchQueue(
            label: "io.github.ender-wang.Remmich.video-stream.\(configuration.assetID)"
        )
        operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.qualityOfService = .userInitiated
        operationQueue.underlyingQueue = delegateQueue
        asset = AVURLAsset(url: assetURL)
        super.init()

        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        sessionConfiguration.waitsForConnectivity = true
        session = URLSession(
            configuration: sessionConfiguration,
            delegate: self,
            delegateQueue: operationQueue
        )
        asset.resourceLoader.setDelegate(self, queue: delegateQueue)
    }

    func invalidate() {
        let result: (
            contexts: [RequestContext],
            requestCount: Int,
            deliveredBytes: Int64
        )? = lock.withLock {
            guard !isInvalidated else { return nil }
            isInvalidated = true
            let values = Array(loadingContexts.values)
            loadingContexts.removeAll()
            contextsByTaskID.removeAll()
            taskIDByLoadingRequest.removeAll()
            return (values, startedRequestCount, deliveredByteCount)
        }
        guard let result else { return }
        session.invalidateAndCancel()
        for context in result.contexts {
            context.finish(with: AuthenticatedVideoStreamError.cancelled)
        }
        let assetPrefix = assetID.prefix(8)
        Self.logger.debug(
            "Video stream closed asset=\(assetPrefix, privacy: .private) requests=\(result.requestCount) deliveredBytes=\(result.deliveredBytes) outstanding=\(result.contexts.count)"
        )
    }

    deinit {
        session?.invalidateAndCancel()
    }

    static func request(
        configuration: AuthenticatedVideoStreamConfiguration,
        range: Range<Int64>?
    ) -> URLRequest {
        var request = URLRequest(url: configuration.url)
        request.setValue(configuration.authorization, forHTTPHeaderField: "Authorization")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range, !range.isEmpty {
            let value = "bytes=\(range.lowerBound)-\(range.upperBound - 1)"
            request.setValue(value, forHTTPHeaderField: "Range")
        }
        return request
    }

    static func totalLength(
        response: HTTPURLResponse
    ) -> Int64? {
        if let contentRange = parsedContentRange(response: response) {
            return contentRange.totalLength
        }
        guard response.statusCode == 200 else { return nil }
        let length = response.expectedContentLength
        return length > 0 ? length : nil
    }

    static func responsePlan(
        response: HTTPURLResponse,
        requestedOffset: Int64,
        requestedLength: Int64,
        requestsToEnd: Bool
    ) throws -> AuthenticatedVideoResponsePlan {
        if let error = responseError(statusCode: response.statusCode) {
            throw error
        }
        let contentLength = totalLength(response: response)
        switch response.statusCode {
        case 206:
            guard let parsed = parsedContentRange(response: response),
                  parsed.range.lowerBound == requestedOffset
            else {
                throw AuthenticatedVideoStreamError.invalidRange
            }
            let responseByteCount = parsed.range.upperBound - parsed.range.lowerBound
            let expected = requestsToEnd
                ? responseByteCount
                : min(requestedLength, responseByteCount)
            guard expected > 0 else {
                throw AuthenticatedVideoStreamError.invalidRange
            }
            return AuthenticatedVideoResponsePlan(
                contentLength: contentLength,
                responseRange: parsed.range,
                expectedByteCount: expected
            )
        case 200:
            guard requestedOffset == 0 else {
                throw AuthenticatedVideoStreamError.invalidRange
            }
            let expected = contentLength.map {
                requestsToEnd ? $0 : min(requestedLength, $0)
            } ?? (requestsToEnd ? nil : requestedLength)
            return AuthenticatedVideoResponsePlan(
                contentLength: contentLength,
                responseRange: contentLength.map { 0 ..< $0 },
                expectedByteCount: expected
            )
        default:
            throw AuthenticatedVideoStreamError.invalidResponse
        }
    }

    private static func responseError(
        statusCode: Int
    ) -> AuthenticatedVideoStreamError? {
        switch statusCode {
        case 200, 206:
            nil
        case 401, 403:
            .unauthorized
        case 404, 410:
            .unavailable(statusCode: statusCode)
        case 408, 429, 500 ... 599:
            .network(retryable: true)
        case 416:
            .invalidRange
        default:
            .unavailable(statusCode: statusCode)
        }
    }

    private static func parsedContentRange(
        response: HTTPURLResponse
    ) -> (range: Range<Int64>, totalLength: Int64)? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range"),
              value.lowercased().hasPrefix("bytes ")
        else { return nil }
        let fields = value.dropFirst(6).split(separator: "/", maxSplits: 1)
        guard fields.count == 2,
              let totalLength = Int64(fields[1]),
              totalLength > 0
        else { return nil }
        let bounds = fields[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let lower = Int64(bounds[0]),
              let inclusiveUpper = Int64(bounds[1]),
              lower >= 0,
              inclusiveUpper >= lower,
              inclusiveUpper < Int64.max
        else { return nil }
        return (lower ..< (inclusiveUpper + 1), totalLength)
    }

    private func start(_ loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let context: RequestContext
        if let dataRequest = loadingRequest.dataRequest {
            let offset = max(dataRequest.currentOffset, dataRequest.requestedOffset)
            let requestedLength = max(1, Int64(dataRequest.requestedLength))
            let upperBound = offset.addingReportingOverflow(requestedLength)
            context = RequestContext(
                loadingRequest: loadingRequest,
                requestedRange: offset ..< (dataRequest.requestsAllDataToEndOfResource || upperBound.overflow
                    ? Int64.max : upperBound.partialValue),
                sendsData: true
            )
        } else if loadingRequest.contentInformationRequest != nil {
            context = RequestContext(
                loadingRequest: loadingRequest,
                requestedRange: 0 ..< 2,
                sendsData: false
            )
        } else {
            loadingRequest.finishLoading(with: AuthenticatedVideoStreamError.invalidRequest)
            return false
        }

        let accepted = lock.withLock {
            guard !isInvalidated else { return false }
            nextRequestSequence += 1
            context.sequence = nextRequestSequence
            loadingContexts[ObjectIdentifier(loadingRequest)] = context
            return true
        }
        guard accepted else {
            context.finish(with: AuthenticatedVideoStreamError.cancelled)
            return false
        }
        schedulePump()
        return true
    }

    /// Called for both loaded-range changes and advancing playhead time, including seeks.
    func updateBuffering(duration: Double, secondsAhead: Double) {
        lock.withLock { bufferPolicy.update(duration: duration, ahead: secondsAhead) }
        schedulePump()
    }

    private func schedulePump() {
        let shouldSchedule = lock.withLock {
            guard !isInvalidated, !pumpScheduled else { return false }
            pumpScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        // Let AVFoundation publish playable ranges before admitting another bounded read.
        delegateQueue.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in self?.pump() }
    }

    private func pump() {
        let task: URLSessionDataTask? = lock.withLock {
            pumpScheduled = false
            guard !isInvalidated, contextsByTaskID.isEmpty else { return nil }
            func isMetadata(_ context: RequestContext) -> Bool {
                context.requestedByteCount <= 262_144 || !context.sendsData
                    || contentLength.map { context.nextOffset >= max(0, $0 - 262_144) } == true
            }
            let candidates = loadingContexts.values.sorted {
                let first = isMetadata($0), second = isMetadata($1)
                return first != second ? first : $0.sequence < $1.sequence
            }
            for context in candidates {
                // Small finite probes and EOF metadata remain serviceable while media is paced.
                let metadata = isMetadata(context)
                guard metadata || !bufferPolicy.isThrottled else { continue }
                let count = metadata ? Int64(65536) : bufferPolicy.chunkBytes(contentLength: contentLength)
                guard let range = context.beginChunk(maxBytes: count) else { continue }
                let task = session.dataTask(with: Self.request(configuration: configuration, range: range))
                contextsByTaskID[task.taskIdentifier] = context
                taskIDByLoadingRequest[ObjectIdentifier(context.loadingRequest)] = task.taskIdentifier
                startedRequestCount += 1
                return task
            }
            return nil
        }
        task?.resume()
    }

    private func cancel(_ loadingRequest: AVAssetResourceLoadingRequest) {
        let result = lock.withLock {
            let key = ObjectIdentifier(loadingRequest)
            let context = loadingContexts.removeValue(forKey: key)
            let taskID = taskIDByLoadingRequest.removeValue(forKey: key)
            if let taskID {
                contextsByTaskID.removeValue(forKey: taskID)
            }
            return (context, taskID)
        }
        result.0?.abandon()
        if let taskID = result.1 {
            session.getAllTasks { tasks in tasks.first { $0.taskIdentifier == taskID }?.cancel() }
        }
        schedulePump()
    }

    private func finish(_ context: RequestContext, error: (any Error)? = nil) {
        lock.withLock { _ = loadingContexts.removeValue(forKey: ObjectIdentifier(context.loadingRequest)) }
        context.finish(with: error)
    }

    private func context(for taskID: Int) -> RequestContext? {
        lock.withLock { contextsByTaskID[taskID] }
    }

    private func removeContext(for taskID: Int) -> RequestContext? {
        lock.withLock {
            guard let context = contextsByTaskID.removeValue(forKey: taskID) else {
                return nil
            }
            taskIDByLoadingRequest.removeValue(
                forKey: ObjectIdentifier(context.loadingRequest)
            )
            return context
        }
    }

    private func apply(
        response: HTTPURLResponse,
        to loadingRequest: AVAssetResourceLoadingRequest
    ) {
        guard let information = loadingRequest.contentInformationRequest else { return }
        information.isByteRangeAccessSupported = response.statusCode == 206
            || response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
        if let totalLength = Self.totalLength(response: response) {
            information.contentLength = totalLength
            contentLengthChanged(totalLength)
        }
        if let mimeType = response.mimeType,
           let type = UTType(mimeType: mimeType)
        {
            information.contentType = type.identifier
        }
    }

    private final class RequestContext: @unchecked Sendable {
        let loadingRequest: AVAssetResourceLoadingRequest
        let requestedRange: Range<Int64>
        let sendsData: Bool
        var sequence = 0 // Assigned once under the source lock before publication.
        private let lock = NSLock()
        private var progress: VideoStreamRequestProgress
        private var isFinished = false

        var requestedByteCount: Int64 {
            requestedRange.upperBound - requestedRange.lowerBound
        }

        var nextOffset: Int64 {
            lock.withLock { progress.offset }
        }

        var activeChunk: Range<Int64> {
            lock.withLock { progress.chunkRange }
        }

        init(loadingRequest: AVAssetResourceLoadingRequest, requestedRange: Range<Int64>, sendsData: Bool) {
            self.loadingRequest = loadingRequest
            self.requestedRange = requestedRange
            self.sendsData = sendsData
            progress = VideoStreamRequestProgress(requestedRange: requestedRange)
        }

        func beginChunk(maxBytes: Int64) -> Range<Int64>? {
            lock.withLock {
                guard !isFinished else { return nil }
                return progress.beginChunk(maxBytes: maxBytes)
            }
        }

        func configure(plan: AuthenticatedVideoResponsePlan, applyResponse: (AVAssetResourceLoadingRequest) -> Void) -> Bool {
            lock.withLock {
                guard !isFinished, plan.expectedByteCount != nil else { return false }
                progress.configure(plan)
                applyResponse(loadingRequest)
                return true
            }
        }

        func respond(with data: Data) -> (deliveredByteCount: Int64, isChunkComplete: Bool, isComplete: Bool) {
            let result = lock.withLock { () -> (Int64, Bool, Bool) in
                guard !isFinished else { return (0, false, false) }
                let count = progress.consume(byteCount: Int64(data.count))
                if count > 0 {
                    loadingRequest.dataRequest?.respond(with: count == Int64(data.count) ? data : Data(data.prefix(Int(count))))
                }
                let complete = progress.requestComplete
                if complete {
                    isFinished = true
                }
                return (count, progress.chunkComplete, complete)
            }
            if result.2 {
                loadingRequest.finishLoading()
            }
            return result
        }

        func receivedExpectedBytes() -> Bool {
            lock.withLock { progress.chunkComplete }
        }

        func finish(with error: (any Error)? = nil) {
            let shouldFinish = lock.withLock {
                guard !isFinished else { return false }
                isFinished = true
                return true
            }
            guard shouldFinish else { return }
            if let error {
                loadingRequest.finishLoading(with: error)
            } else {
                loadingRequest.finishLoading()
            }
        }

        func abandon() {
            lock.withLock { isFinished = true }
        }
    }
}

extension AuthenticatedVideoStreamSource: AVAssetResourceLoaderDelegate {
    nonisolated func resourceLoader(
        _: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        start(loadingRequest)
    }

    nonisolated func resourceLoader(
        _: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        cancel(loadingRequest)
    }
}

extension AuthenticatedVideoStreamSource: URLSessionDataDelegate, URLSessionTaskDelegate {
    nonisolated func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let context = context(for: dataTask.taskIdentifier),
              let response = response as? HTTPURLResponse
        else {
            completionHandler(.cancel)
            return
        }

        let plan: AuthenticatedVideoResponsePlan
        do {
            plan = try Self.responsePlan(
                response: response,
                requestedOffset: context.activeChunk.lowerBound,
                requestedLength: Int64(context.activeChunk.count),
                requestsToEnd: false
            )
        } catch {
            _ = removeContext(for: dataTask.taskIdentifier)
            finish(context, error: error)
            schedulePump()
            completionHandler(.cancel)
            return
        }

        lock.withLock {
            if let length = plan.contentLength {
                contentLength = length
            }
        }
        guard context.configure(
            plan: plan,
            applyResponse: { [self] in apply(response: response, to: $0) }
        ) else {
            completionHandler(.cancel)
            return
        }
        if !context.sendsData {
            _ = removeContext(for: dataTask.taskIdentifier)
            finish(context)
            schedulePump()
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    nonisolated func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard let context = context(for: dataTask.taskIdentifier), context.sendsData else {
            return
        }
        let consumed = context.respond(with: data)
        if consumed.deliveredByteCount > 0 {
            lock.withLock {
                deliveredByteCount += consumed.deliveredByteCount
            }
        }
        if consumed.isChunkComplete {
            _ = removeContext(for: dataTask.taskIdentifier)
            if consumed.isComplete {
                finish(context)
            }
            dataTask.cancel()
            schedulePump()
        }
    }

    nonisolated func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let context = removeContext(for: task.taskIdentifier) else { return }
        if let error {
            let normalized = (error as NSError).code == NSURLErrorCancelled
                ? AuthenticatedVideoStreamError.cancelled : error
            finish(context, error: normalized)
        } else if !context.receivedExpectedBytes() {
            finish(context, error: AuthenticatedVideoStreamError.invalidResponse)
        }
        schedulePump()
    }

    nonisolated func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(MediaRedirectAuthorizationDelegate.redirectRequest(
            originalRequest: task.originalRequest,
            proposedRequest: request
        ))
    }
}
