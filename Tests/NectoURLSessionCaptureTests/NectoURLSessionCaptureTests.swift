//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation
import NectoDefaultPlugins
import Testing

@testable import NectoURLSessionCapture

/// Collects what the capture reports, the way `NectoNetworkPlugin` would.
private final class Records: NectoNetworkReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var reported: [NectoNetworkRecord] = []

    func report(_ record: NectoNetworkRecord) {
        lock.withLock { reported.append(record) }
    }

    var all: [NectoNetworkRecord] { lock.withLock { reported } }

    /// Every finished record of a request to `server`. The capture is process-wide,
    /// so requests other tests make are reported here too.
    func finished(on server: LocalHTTPServer) -> [NectoNetworkRecord] {
        all.filter { $0.state != .pending && $0.url.hasPrefix(server.baseURL.absoluteString) }
    }

    /// The finished record of the request to `path`, once it has been reported.
    func finished(path: String) async throws -> NectoNetworkRecord {
        for _ in 0..<200 {
            if let record = all.last(where: { $0.state != .pending && URL(string: $0.url)?.path == path }) {
                return record
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.fileReadUnknown)
    }
}

/// Lets a test hold a response open and let go of it.
private final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func open() { semaphore.signal() }
    func wait(upTo seconds: Int) { _ = semaphore.wait(timeout: .now() + .seconds(seconds)) }
}

/// Records what a delegate-driven session is told, in the order it is told.
private final class DelegateWitness: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    private var finished: CheckedContinuation<[String], Never>?
    private var result: [String]?
    /// Called for each piece of data, after it has been noted.
    var onData: (@Sendable () -> Void)?

    /// Everything the delegate saw, once the task has completed.
    func events() async -> [String] {
        await withCheckedContinuation { continuation in
            let known = lock.withLock { () -> [String]? in
                if result == nil { finished = continuation }
                return result
            }
            if let known { continuation.resume(returning: known) }
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse
    ) async -> URLSession.ResponseDisposition {
        lock.withLock { seen.append("response") }
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { if seen.last != "data" { seen.append("data") } }
        onData?()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (waiting, events) = lock.withLock { () -> (CheckedContinuation<[String], Never>?, [String]) in
            seen.append(error == nil ? "complete" : "failed")
            result = seen
            defer { finished = nil }
            return (finished, seen)
        }
        waiting?.resume(returning: events)
    }
}

/// The capture is installed process-wide, so these run one at a time.
@Suite("URLSession capture", .serialized)
struct NectoURLSessionCaptureTests {
    private static func echo(_ request: LocalHTTPServer.Request, _ response: LocalHTTPServer.Response) {
        let payload: [String: Any] = [
            "method": request.method,
            "headers": request.headers,
            "body": String(decoding: request.body, as: UTF8.self),
        ]
        response.send(
            headers: ["Content-Type": "application/json"],
            body: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        )
    }

    /// A session an app configured itself, with the capture in front as documented.
    private func session(
        _ configuration: URLSessionConfiguration = .ephemeral,
        captured: Bool = true,
        delegate: (any URLSessionDelegate)? = nil
    ) -> URLSession {
        if captured {
            configuration.protocolClasses = [NectoURLSessionCapture.protocolClass]
                + (configuration.protocolClasses ?? [])
        }
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    @Test("reports the body of a request that carries one")
    func capturesRequestBody() async throws {
        let server = try LocalHTTPServer(respond: Self.echo)
        defer { server.stop() }
        let records = Records()
        NectoURLSessionCapture.install(reporting: records)
        defer { NectoURLSessionCapture.uninstall() }

        var request = URLRequest(url: server.baseURL.appending(path: "echo"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"name":"necto"}"#.utf8)
        let (_, response) = try await session().data(for: request)

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let arrived = try #require(server.requests.first)
        #expect(String(decoding: arrived.body, as: UTF8.self) == #"{"name":"necto"}"#)
        #expect(arrived.headers["content-length"] == "16")

        let record = try await records.finished(path: "/echo")
        #expect(record.state == .completed)
        #expect(record.requestBody?.text == #"{"name":"necto"}"#)
        #expect(record.requestBody?.byteCount == 16)
    }

    @Test("leaves the app's cookies working", arguments: [false, true])
    func keepsCookies(captured: Bool) async throws {
        let server = try LocalHTTPServer { request, response in
            if request.path == "/login" {
                response.send(headers: ["Set-Cookie": "session=necto; Path=/"])
            } else {
                Self.echo(request, response)
            }
        }
        defer { server.stop() }
        let records = Records()
        NectoURLSessionCapture.install(reporting: records)
        defer { NectoURLSessionCapture.uninstall() }

        let storage = HTTPCookieStorage.shared
        let forget = { storage.cookies(for: server.baseURL)?.forEach(storage.deleteCookie) }
        forget()
        defer { forget() }

        let session = session(.default, captured: captured)
        _ = try await session.data(from: server.baseURL.appending(path: "login"))
        _ = try await session.data(from: server.baseURL.appending(path: "profile"))

        #expect(storage.cookies(for: server.baseURL)?.map(\.name) == ["session"])
        #expect(server.requests.last?.headers["cookie"] == "session=necto")
    }

    @Test("hands over a streamed response as it arrives")
    func streamsResponses() async throws {
        let gate = Gate()
        let server = try LocalHTTPServer { _, response in
            response.sendHead(status: 200, headers: ["Content-Type": "text/event-stream"])
            response.write(Data("first\n".utf8))
            gate.wait(upTo: 3)
            response.write(Data("second\n".utf8))
        }
        defer { server.stop() }
        let records = Records()
        NectoURLSessionCapture.install(reporting: records)
        defer { NectoURLSessionCapture.uninstall() }

        let (bytes, _) = try await session().bytes(from: server.baseURL.appending(path: "stream"))
        var lines = bytes.lines.makeAsyncIterator()
        let started = ContinuousClock.now
        let first = try await lines.next()
        let waited = ContinuousClock.now - started
        gate.open()

        // The server holds the rest back for three seconds unless the first line was
        // read, so a line that took that long was not streamed.
        #expect(first == "first")
        #expect(waited < .seconds(2))
        #expect(try await lines.next() == "second")

        let record = try await records.finished(path: "/stream")
        #expect(record.responseBody?.text == "first\nsecond\n")
    }

    /// Handing a redirect to the app's session instead looks right and is not: told
    /// the load was cancelled for the redirect, the session now and then reports that
    /// cancellation rather than following. Once in some hundreds of requests is enough
    /// to matter, so this asks that many times.
    @Test("follows a redirect every time and hands over where it led")
    func followsRedirects() async throws {
        let server = try LocalHTTPServer { request, response in
            if request.path == "/old" {
                response.send(status: 302, headers: ["Location": "/new"], body: Data("moved".utf8))
            } else {
                Self.echo(request, response)
            }
        }
        defer { server.stop() }
        let records = Records()
        NectoURLSessionCapture.install(reporting: records)
        defer { NectoURLSessionCapture.uninstall() }

        let session = session()
        for _ in 0..<500 {
            let (_, response) = try await session.data(from: server.baseURL.appending(path: "old"))
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(response.url?.path == "/new")
        }

        let finished = records.finished(on: server)
        #expect(finished.count == 500)
        #expect(finished.allSatisfy { $0.state == .completed && $0.statusCode == 200 })
    }

    @Test("keeps requests that run at once apart")
    func keepsConcurrentRequestsApart() async throws {
        let server = try LocalHTTPServer { request, response in
            response.send(headers: ["Content-Type": "text/plain"], body: Data(request.path.utf8))
        }
        defer { server.stop() }
        let records = Records()
        NectoURLSessionCapture.install(reporting: records)
        defer { NectoURLSessionCapture.uninstall() }

        let session = session()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    let (data, _) = try await session.data(from: server.baseURL.appending(path: "item/\(index)"))
                    #expect(String(decoding: data, as: UTF8.self) == "/item/\(index)")
                }
            }
            try await group.waitForAll()
        }

        for index in 0..<50 {
            let record = try await records.finished(path: "/item/\(index)")
            #expect(record.responseBody?.text == "/item/\(index)")
        }
        #expect(records.finished(on: server).count == 50)
    }

    @Test("tells a delegate about the response before its data", arguments: [false, true])
    func keepsDelegateOrder(captured: Bool) async throws {
        let server = try LocalHTTPServer(respond: Self.echo)
        defer { server.stop() }
        let records = Records()
        NectoURLSessionCapture.install(reporting: records)
        defer { NectoURLSessionCapture.uninstall() }

        let witness = DelegateWitness()
        session(captured: captured, delegate: witness)
            .dataTask(with: server.baseURL.appending(path: "ordered"))
            .resume()

        let seen = await witness.events()
        #expect(seen == ["response", "data", "complete"])
    }

    @Test("gives the app every byte and keeps only the head of a large response")
    func capsTheRecordedBody() async throws {
        let limit = NectoNetworkRecord.Body.captureLimit
        let payload = Data(repeating: UInt8(ascii: "a"), count: limit + 4096)
        let server = try LocalHTTPServer { _, response in
            response.send(headers: ["Content-Type": "text/plain"], body: payload)
        }
        defer { server.stop() }
        let records = Records()
        NectoURLSessionCapture.install(reporting: records)
        defer { NectoURLSessionCapture.uninstall() }

        let (data, _) = try await session().data(from: server.baseURL.appending(path: "large"))
        #expect(data == payload)

        let record = try await records.finished(path: "/large")
        #expect(record.responseByteCount == payload.count)
        #expect(record.responseBody?.byteCount == payload.count)
        #expect(record.responseBody?.isTruncated == true)
        #expect(record.responseBody?.text?.utf8.count == limit)
    }

    @Test("reports a request the app cancels part way as failed")
    func reportsCancellation() async throws {
        let gate = Gate()
        let server = try LocalHTTPServer { _, response in
            response.sendHead(status: 200, headers: ["Content-Type": "text/event-stream"])
            response.write(Data("first\n".utf8))
            gate.wait(upTo: 3)
        }
        defer { server.stop() }
        let records = Records()
        NectoURLSessionCapture.install(reporting: records)
        defer { NectoURLSessionCapture.uninstall() }

        let witness = DelegateWitness()
        let task = session(delegate: witness).dataTask(with: server.baseURL.appending(path: "cancelled"))
        witness.onData = { task.cancel() }
        task.resume()

        #expect(await witness.events() == ["response", "data", "failed"])
        let record = try await records.finished(path: "/cancelled")
        gate.open()
        #expect(record.state == .failed)
        // Long enough for the response the server was holding back to have ended too.
        try await Task.sleep(for: .milliseconds(100))
        #expect(records.finished(on: server).count == 1)
    }

    @Test("captures the shared session once installed")
    func capturesSharedSession() async throws {
        let server = try LocalHTTPServer(respond: Self.echo)
        defer { server.stop() }
        let records = Records()
        NectoURLSessionCapture.install(reporting: records)
        defer { NectoURLSessionCapture.uninstall() }

        _ = try await URLSession.shared.data(from: server.baseURL.appending(path: "shared"))
        #expect(try await records.finished(path: "/shared").statusCode == 200)
    }

    @Test("reports a request that fails and gives the app its error")
    func reportsFailures() async throws {
        let server = try LocalHTTPServer(respond: Self.echo)
        let url = server.baseURL.appending(path: "gone")
        server.stop()
        let records = Records()
        NectoURLSessionCapture.install(reporting: records)
        defer { NectoURLSessionCapture.uninstall() }

        await #expect(throws: URLError.self) {
            _ = try await session().data(from: url)
        }
        #expect(try await records.finished(path: "/gone").state == .failed)
    }
}
