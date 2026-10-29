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
    case unauthorized
    case unavailable(statusCode: Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "The video request could not be created."
        case .invalidResponse:
            "The video server returned an invalid response."
        case .unauthorized:
            "The video session is no longer authorized."
        case let .unavailable(statusCode):
            "The video server returned status \(statusCode)."
        case .cancelled:
            "Video streaming was cancelled."
        }
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
    private var taskIDByLoadingRequest: [ObjectIdentifier: Int] = [:]
    private var isInvalidated = false

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
        let requests: [AVAssetResourceLoadingRequest] = lock.withLock {
            guard !isInvalidated else { return [] }
            isInvalidated = true
            let values = contextsByTaskID.values.map(\.loadingRequest)
            contextsByTaskID.removeAll()
            taskIDByLoadingRequest.removeAll()
            return values
        }
        session.invalidateAndCancel()
        for request in requests {
            request.finishLoading(with: AuthenticatedVideoStreamError.cancelled)
        }
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
            request.setValue(
                "bytes=\(range.lowerBound)-\(range.upperBound - 1)",
                forHTTPHeaderField: "Range"
            )
        }
        return request
    }

    static func totalLength(
        response: HTTPURLResponse
    ) -> Int64? {
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let slash = contentRange.lastIndex(of: "/"),
           let total = Int64(contentRange[contentRange.index(after: slash)...]),
           total > 0
        {
            return total
        }
        let length = response.expectedContentLength
        return length > 0 ? length : nil
    }

    private func start(_ loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let context: RequestContext
        if let dataRequest = loadingRequest.dataRequest {
            let offset = max(dataRequest.currentOffset, dataRequest.requestedOffset)
            let requestedLength = max(1, Int64(dataRequest.requestedLength))
            context = RequestContext(
                loadingRequest: loadingRequest,
                requestedRange: offset ..< (offset + requestedLength),
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

        let task = session.dataTask(with: Self.request(
            configuration: configuration,
            range: context.requestedRange
        ))
        let accepted = lock.withLock {
            guard !isInvalidated else { return false }
            contextsByTaskID[task.taskIdentifier] = context
            taskIDByLoadingRequest[ObjectIdentifier(loadingRequest)] = task.taskIdentifier
            return true
        }
        guard accepted else {
            loadingRequest.finishLoading(with: AuthenticatedVideoStreamError.cancelled)
            return false
        }

        let assetPrefix = assetID.prefix(8)
        Self.logger.debug(
            "Video range started asset=\(assetPrefix, privacy: .private) start=\(context.requestedRange.lowerBound) length=\(context.requestedRange.count)"
        )
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
        let sendsData: Bool

        init(
            loadingRequest: AVAssetResourceLoadingRequest,
            requestedRange: Range<Int64>,
            sendsData: Bool
        ) {
            self.loadingRequest = loadingRequest
            self.requestedRange = requestedRange
            self.sendsData = sendsData
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

        let error: AuthenticatedVideoStreamError? = switch response.statusCode {
        case 200, 206: nil
        case 401, 403: .unauthorized
        default: .unavailable(statusCode: response.statusCode)
        }
        if let error {
            _ = removeContext(for: dataTask.taskIdentifier)
            context.loadingRequest.finishLoading(with: error)
            completionHandler(.cancel)
            return
        }

        apply(response: response, to: context.loadingRequest)
        completionHandler(.allow)
    }

    nonisolated func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard let context = context(for: dataTask.taskIdentifier),
              context.sendsData
        else { return }
        context.loadingRequest.dataRequest?.respond(with: data)
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
