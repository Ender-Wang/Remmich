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
    private var taskIDByLoadingRequest: [ObjectIdentifier: Int] = [:]
    private var isInvalidated = false
    private var startedRequestCount = 0
    private var deliveredByteCount: Int64 = 0

    init(
        configuration: AuthenticatedVideoStreamConfiguration,
        contentLengthChanged: @escaping @Sendable (Int64) -> Void = { _ in }
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

        let sessionConfiguration = URLSessionConfiguration.ephemeral
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
            requests: [AVAssetResourceLoadingRequest],
            requestCount: Int,
            deliveredBytes: Int64
        )? = lock.withLock {
            guard !isInvalidated else { return nil }
            isInvalidated = true
            let values = contextsByTaskID.values.map(\.loadingRequest)
            contextsByTaskID.removeAll()
            taskIDByLoadingRequest.removeAll()
            return (values, startedRequestCount, deliveredByteCount)
        }
        guard let result else { return }
        session.invalidateAndCancel()
        for request in result.requests {
            request.finishLoading(with: AuthenticatedVideoStreamError.cancelled)
        }
        let assetPrefix = assetID.prefix(8)
        Self.logger.debug(
            "Video stream closed asset=\(assetPrefix, privacy: .private) requests=\(result.requestCount) deliveredBytes=\(result.deliveredBytes) outstanding=\(result.requests.count)"
        )
    }

    deinit {
        session?.invalidateAndCancel()
    }

    static func request(
        configuration: AuthenticatedVideoStreamConfiguration,
        range: Range<Int64>?,
        requestsToEnd: Bool = false
    ) -> URLRequest {
        var request = URLRequest(url: configuration.url)
        request.setValue(configuration.authorization, forHTTPHeaderField: "Authorization")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range, !range.isEmpty {
            let value = requestsToEnd
                ? "bytes=\(range.lowerBound)-"
                : "bytes=\(range.lowerBound)-\(range.upperBound - 1)"
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
                requestedRange: offset ..< (upperBound.overflow ? Int64.max : upperBound.partialValue),
                requestsToEnd: dataRequest.requestsAllDataToEndOfResource,
                sendsData: true
            )
        } else if loadingRequest.contentInformationRequest != nil {
            context = RequestContext(
                loadingRequest: loadingRequest,
                requestedRange: 0 ..< 2,
                requestsToEnd: false,
                sendsData: false
            )
        } else {
            loadingRequest.finishLoading(with: AuthenticatedVideoStreamError.invalidRequest)
            return false
        }

        let task = session.dataTask(with: Self.request(
            configuration: configuration,
            range: context.requestedRange,
            requestsToEnd: context.requestsToEnd
        ))
        let accepted: (accepted: Bool, logsInitialRange: Bool) = lock.withLock {
            guard !isInvalidated else { return (false, false) }
            let logsInitialRange = startedRequestCount == 0
            startedRequestCount += 1
            contextsByTaskID[task.taskIdentifier] = context
            taskIDByLoadingRequest[ObjectIdentifier(loadingRequest)] = task.taskIdentifier
            return (true, logsInitialRange)
        }
        guard accepted.accepted else {
            loadingRequest.finishLoading(with: AuthenticatedVideoStreamError.cancelled)
            return false
        }

        if accepted.logsInitialRange {
            let assetPrefix = assetID.prefix(8)
            Self.logger.debug(
                "Video stream opened asset=\(assetPrefix, privacy: .private) initialOffset=\(context.requestedRange.lowerBound) initialLength=\(context.requestedByteCount)"
            )
        }
        task.resume()
        return true
    }

    private func cancel(_ loadingRequest: AVAssetResourceLoadingRequest) {
        let taskID = lock.withLock {
            taskIDByLoadingRequest.removeValue(forKey: ObjectIdentifier(loadingRequest))
        }
        guard let taskID else { return }
        _ = lock.withLock {
            contextsByTaskID.removeValue(forKey: taskID)
        }
        session.getAllTasks { tasks in
            tasks.first { $0.taskIdentifier == taskID }?.cancel()
        }
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
        let requestsToEnd: Bool
        let sendsData: Bool
        private let lock = NSLock()
        private var expectedByteCount: Int64?
        private var deliveredByteCount: Int64 = 0

        var requestedByteCount: Int64 {
            requestedRange.upperBound - requestedRange.lowerBound
        }

        init(
            loadingRequest: AVAssetResourceLoadingRequest,
            requestedRange: Range<Int64>,
            requestsToEnd: Bool,
            sendsData: Bool
        ) {
            self.loadingRequest = loadingRequest
            self.requestedRange = requestedRange
            self.requestsToEnd = requestsToEnd
            self.sendsData = sendsData
        }

        func configure(expectedByteCount: Int64?) {
            lock.withLock {
                self.expectedByteCount = expectedByteCount
            }
        }

        func consume(_ data: Data) -> (payload: Data, isComplete: Bool) {
            lock.withLock {
                guard let expectedByteCount else {
                    deliveredByteCount += Int64(data.count)
                    return (data, false)
                }
                let remaining = max(0, expectedByteCount - deliveredByteCount)
                let acceptedCount = min(Int64(data.count), remaining)
                let payload = acceptedCount == Int64(data.count)
                    ? data
                    : Data(data.prefix(Int(acceptedCount)))
                deliveredByteCount += acceptedCount
                return (payload, deliveredByteCount >= expectedByteCount)
            }
        }

        func receivedExpectedBytes() -> Bool {
            lock.withLock {
                guard let expectedByteCount else { return true }
                return deliveredByteCount >= expectedByteCount
            }
        }
    }
}

extension AuthenticatedVideoStreamSource: AVAssetResourceLoaderDelegate {
    func resourceLoader(
        _: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        start(loadingRequest)
    }

    func resourceLoader(
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
                requestedOffset: context.requestedRange.lowerBound,
                requestedLength: context.requestedByteCount,
                requestsToEnd: context.requestsToEnd
            )
        } catch {
            _ = removeContext(for: dataTask.taskIdentifier)
            context.loadingRequest.finishLoading(with: error)
            completionHandler(.cancel)
            return
        }

        apply(response: response, to: context.loadingRequest)
        context.configure(expectedByteCount: plan.expectedByteCount)
        if !context.sendsData {
            _ = removeContext(for: dataTask.taskIdentifier)
            context.loadingRequest.finishLoading()
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
        let consumed = context.consume(data)
        if !consumed.payload.isEmpty {
            context.loadingRequest.dataRequest?.respond(with: consumed.payload)
            lock.withLock {
                deliveredByteCount += Int64(consumed.payload.count)
            }
        }
        if consumed.isComplete {
            _ = removeContext(for: dataTask.taskIdentifier)
            context.loadingRequest.finishLoading()
            dataTask.cancel()
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
                ? AuthenticatedVideoStreamError.cancelled
                : error
            context.loadingRequest.finishLoading(with: normalized)
        } else if !context.receivedExpectedBytes() {
            context.loadingRequest.finishLoading(
                with: AuthenticatedVideoStreamError.invalidResponse
            )
        } else {
            context.loadingRequest.finishLoading()
        }
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
