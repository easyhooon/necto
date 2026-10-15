//
//  Copyright (c) 2026 Viva Republica, Inc.
//

#if !DEBUG
import Foundation
import NectoNetworkPlugin
import NectoURLSessionCapturePlugin
import Testing

private final class ReleaseReporter: NectoNetworkReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var records: Int { lock.withLock { count } }
    func report(_ record: NectoNetworkRecord) { lock.withLock { count += 1 } }
}

@Test("Release capture leaves native requests working without recording")
func releaseCaptureIsDisabled() async throws {
    let server = try LocalHTTPServer { _, response in response.send(body: Data("native".utf8)) }
    defer { server.stop() }
    let reporter = ReleaseReporter()
    NectoURLSessionCapture.install(reporting: reporter)
    defer { NectoURLSessionCapture.uninstall() }
    let (data, _) = try await URLSession.shared.data(from: server.baseURL)
    #expect(data == Data("native".utf8))
    #expect(reporter.records == 0)
}
#endif
