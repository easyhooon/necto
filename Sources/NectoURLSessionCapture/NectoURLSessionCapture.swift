//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import NectoDefaultPlugins
import NectoModel
import NectoSDK
import Foundation

/// The network plugin with `URLSession` capture already wired.
///
/// For the app that just wants its traffic in Necto:
///
/// ```swift
/// NectoSDK.register(URLSessionNetworkPlugin())
/// ```
///
/// Capture starts when the plugin is registered — the two are one decision, so they
/// are one line. An app that reports some requests itself as well reaches the plugin
/// through `network`.
public struct URLSessionNetworkPlugin: NectoPlugin {
    public let network = NectoNetworkPlugin()

    public var id: String { network.id }

    public var panel: NectoPluginPanel? { network.panel }

    public init() {}

    public func register(_ necto: NectoRegistrar) {
        network.register(necto)
        NectoURLSessionCapture.install(reporting: network)
    }
}

/// Captures `URLSession` traffic and reports it to whatever takes reports.
///
/// One possible source of network records, offered because many apps do use
/// `URLSession` and wiring it up by hand is tedious. It is a module of its own so
/// that an app which routes traffic some other way never links it, and so that Necto
/// never assumes this is how requests are made.
///
/// `URLSessionNetworkPlugin` above is the one-liner; these entry points are for an
/// app that pairs the capture with a reporter of its own.
public enum NectoURLSessionCapture {
    /// Starts capturing. Records go to `reporter` until `uninstall()` is called.
    ///
    /// This installs a `URLProtocol` into the app's loading system, which covers
    /// `URLSession.shared`. A session built from a configuration takes its protocols
    /// from that configuration, `URLSessionConfiguration.default` included, so it
    /// needs `NectoURLSessionCapture.protocolClass` at the front of its own
    /// `protocolClasses`.
    /// Takes anything that reports, not the shipped plugin specifically. An app that
    /// decrypts its own traffic reports from wherever it already knows about a request.
    public static func install(reporting reporter: any NectoNetworkReporting) {
        NectoNetworkObserver.start { record in reporter.report(record) }
    }

    public static func uninstall() {
        NectoNetworkObserver.stop()
    }

    @available(*, deprecated, renamed: "uninstall()")
    public static func remove() {
        uninstall()
    }

    /// For apps that build their own `URLSessionConfiguration`.
    ///
    /// What that configuration says about cookies cannot be seen from the capture,
    /// so no cookie is sent or stored for the requests it captures, whatever the
    /// configuration's own policy is.
    public static var protocolClass: AnyClass { NectoConfiguredNetworkObserver.self }
}

/// Observes URLSession traffic without the app having to report anything.
///
/// `URLProtocol` is the only hook that sees requests an app already makes. Registering
/// one and then re-issuing the request through a session that excludes it lets Necto
/// time and inspect the exchange while the app's own code stays untouched.
///
/// It only observes: the request is passed through unchanged, and the response is
/// handed back as it arrives — the response first, then its data piece by piece — so
/// a stream stays a stream and a delegate is told things in the order it expects.
///
/// The re-issued request runs in a session of Necto's own. This class is the one
/// registered with the loading system, which reaches `URLSession.shared` and nothing
/// else, so its session is built from the default configuration and handles cookies
/// through the shared store exactly as the shared session does. A session the app
/// configured itself goes through `NectoConfiguredNetworkObserver` instead.
///
/// A redirect is followed here, and the app is handed where it led. Its session's
/// delegate is not asked: a `URLProtocol` can pass a redirect on, but is never told
/// what the delegate answered, and a load that guesses goes wrong one way or the other.
class NectoNetworkObserver: URLProtocol, @unchecked Sendable {
    /// Marks a request that this protocol already handled, so re-issuing it does not
    /// recurse back into the observer.
    private static let handledKey = "NectoNetworkObserverHandled"

    /// URLProtocol is instantiated by the loading system, so the reporting callback
    /// has to reach it through shared state rather than an initialiser.
    private final class Reporter: @unchecked Sendable {
        private let lock = NSLock()
        private var report: (@Sendable (NectoNetworkRecord) -> Void)?

        func set(_ report: (@Sendable (NectoNetworkRecord) -> Void)?) {
            lock.withLock { self.report = report }
        }

        func emit(_ record: NectoNetworkRecord) {
            let report = lock.withLock { self.report }
            report?(record)
        }
    }

    /// Routes what the re-issuing session reports to the observer that started the
    /// task. A completion handler would only hear about a response once it is over.
    private final class Loader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        // Keyed by the task itself: a task identifier is unique within one session,
        // and this delegate serves more than one.
        private var observers: [ObjectIdentifier: NectoNetworkObserver] = [:]

        func add(_ observer: NectoNetworkObserver, for task: URLSessionTask) {
            lock.withLock { observers[ObjectIdentifier(task)] = observer }
        }

        func remove(_ task: URLSessionTask) {
            lock.withLock { _ = observers.removeValue(forKey: ObjectIdentifier(task)) }
        }

        private func observer(for task: URLSessionTask) -> NectoNetworkObserver? {
            lock.withLock { observers[ObjectIdentifier(task)] }
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            observer(for: dataTask)?.receive(response)
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            observer(for: dataTask)?.receive(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            let observer = observer(for: task)
            remove(task)
            observer?.complete(error: error)
        }
    }

    private static let reporter = Reporter()
    private static let loader = Loader()

    /// The session that re-issues requests reaching this class. One for all of them,
    /// so connections are reused the way the app's own session would reuse them.
    class var loadingSession: URLSession { sharedSession }

    /// For requests from `URLSession.shared`, whose cookie policy is known.
    private static let sharedSession = makeSession(handlesCookies: true)

    /// For requests from a configuration of the app's own, whose cookie policy is not.
    fileprivate static let cookielessSession = makeSession(handlesCookies: false)

    /// A session that lives as long as the process does.
    private static func makeSession(handlesCookies: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.default
        // Without these protocols, or the re-issued request would be intercepted again.
        configuration.protocolClasses = configuration.protocolClasses?.filter { $0 is NectoNetworkObserver.Type == false }
        // Whether a response may be cached is for the app's session to say, and its
        // cache cannot be seen from here, so a captured request always loads.
        configuration.urlCache = nil
        if !handlesCookies {
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
        }
        // Every captured session shares this one, so its limit per host would count
        // across all of them, and a few long-lived streams would hold the rest back.
        configuration.httpMaximumConnectionsPerHost = 64
        return URLSession(configuration: configuration, delegate: loader, delegateQueue: nil)
    }

    /// Guards everything below: the loading system and the session call in from
    /// different threads.
    private let lock = NSLock()
    private var observedTask: URLSessionDataTask?
    /// Set once the load has ended: the client was told how, or stopped it.
    private var isFinished = false
    private var received = 0
    /// The head of the response body, kept for the record. The client gets all of it.
    private var responseData = Data()
    private var httpResponse: HTTPURLResponse?
    private var startedAt = Date()
    private let recordID = UUID().uuidString

    /// Starts observing. Records are handed to `report` as they start and finish.
    static func start(report: @escaping @Sendable (NectoNetworkRecord) -> Void) {
        reporter.set(report)
        URLProtocol.registerClass(NectoNetworkObserver.self)
    }

    static func stop() {
        URLProtocol.unregisterClass(NectoNetworkObserver.self)
        reporter.set(nil)
    }

    private static func emit(_ record: NectoNetworkRecord) {
        reporter.emit(record)
    }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        guard URLProtocol.property(forKey: handledKey, in: request) == nil else { return false }
        return request.url?.scheme == "http" || request.url?.scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)

        let task = Self.loadingSession.dataTask(with: mutable as URLRequest)
        lock.withLock {
            startedAt = Date()
            observedTask = task
        }
        Self.emit(makeRecord(state: .pending))
        Self.loader.add(self, for: task)
        task.resume()
    }

    /// Called once the load is over, and also when the app cancels it part way.
    override func stopLoading() {
        guard let task = lock.withLock({ observedTask }) else { return }
        let wasLoading = finish()
        Self.loader.remove(task)
        task.cancel()
        if wasLoading {
            // The cancelled task may still hold the body stream, so it is left alone.
            Self.emit(makeRecord(state: .failed, error: URLError(.cancelled), readsBodyStream: false))
        }
    }

    // MARK: Loading

    /// Whether the client may still be told about this load.
    private var isLoading: Bool { lock.withLock { !isFinished } }

    /// Ends the load, once. False when it had already ended.
    private func finish() -> Bool {
        lock.withLock {
            guard !isFinished else { return false }
            isFinished = true
            return true
        }
    }

    private func receive(_ response: URLResponse) {
        guard isLoading else { return }
        lock.withLock { httpResponse = response as? HTTPURLResponse }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    private func receive(_ data: Data) {
        guard isLoading else { return }
        lock.withLock {
            received += data.count
            // One byte past the limit is kept, which is how the record's body knows
            // that it was cut.
            let room = NectoNetworkRecord.Body.captureLimit + 1 - responseData.count
            if room > 0 { responseData.append(data.prefix(room)) }
        }
        client?.urlProtocol(self, didLoad: data)
    }

    private func complete(error: (any Error)?) {
        guard finish() else { return }
        if let error {
            Self.emit(makeRecord(state: .failed, error: error))
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            Self.emit(makeRecord(state: .completed))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    // MARK: Recording

    private func makeRecord(
        state: NectoNetworkRecord.State,
        error: (any Error)? = nil,
        readsBodyStream: Bool = true
    ) -> NectoNetworkRecord {
        let (httpResponse, received, responseData, startedAt) = lock.withLock {
            (self.httpResponse, self.received, self.responseData, self.startedAt)
        }
        let responseHeaders = httpResponse?.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            if let key = entry.key as? String { result[key] = String(describing: entry.value) }
        } ?? [:]
        let responseHead = NectoNetworkRecord.Body(
            data: responseData,
            contentType: httpResponse?.value(forHTTPHeaderField: "Content-Type")
        )

        return NectoNetworkRecord(
            id: recordID,
            method: request.httpMethod ?? "GET",
            url: request.url?.absoluteString ?? "",
            startedAtMilliseconds: startedAt.timeIntervalSince1970 * 1000,
            state: state,
            statusCode: state == .completed ? httpResponse?.statusCode : nil,
            durationMilliseconds: state == .pending
                ? nil
                : Date().timeIntervalSince(startedAt) * 1000,
            responseByteCount: state == .completed ? received : nil,
            errorSummary: error.map { String(describing: $0) },
            requestHeaders: request.allHTTPHeaderFields ?? [:],
            responseHeaders: responseHeaders,
            // A pending record carries no body yet: the request one is already known,
            // but sending it twice would double the traffic for large uploads.
            requestBody: state == .pending ? nil : requestBodyData(readsStream: readsBodyStream).map {
                NectoNetworkRecord.Body(
                    data: $0,
                    contentType: request.value(forHTTPHeaderField: "Content-Type")
                )
            },
            responseBody: state == .completed && received > 0
                ? NectoNetworkRecord.Body(
                    byteCount: received,
                    isTruncated: responseHead.isTruncated,
                    contentType: responseHead.contentType,
                    text: responseHead.text
                )
                : nil
        )
    }

    /// `httpBody` is nil when the caller used a stream, so fall back to draining it.
    private func requestBodyData(readsStream: Bool) -> Data? {
        if let body = request.httpBody { return body }
        guard readsStream, let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable, data.count < NectoNetworkRecord.Body.captureLimit {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}

/// The protocol an app puts into a configuration of its own.
///
/// What that configuration says about cookies — whether it sets them at all, and into
/// which store — cannot be seen from a `URLProtocol`, and sending the shared store's
/// cookies for a session that turned them off would be a policy of Necto's imposed on
/// the app's. So no cookie is sent or stored for these requests, as before.
final class NectoConfiguredNetworkObserver: NectoNetworkObserver, @unchecked Sendable {
    override class var loadingSession: URLSession { cookielessSession }
}
