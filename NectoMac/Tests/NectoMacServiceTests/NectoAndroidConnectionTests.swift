// Copyright (c) 2026 Viva Republica, Inc.

import Foundation
import NectoModel
import NectoSDK
import NectoTransport
import Testing
@testable import NectoMacService

@Suite("Private Android connections", .serialized, .timeLimit(.minutes(1)))
struct NectoAndroidConnectionTests {
    private final class UnixListener: @unchecked Sendable {
        let acceptor: NectoSocketAcceptor
        let path: String

        init(path: String) throws {
            self.path = path
            unlink(path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            var owned = true
            defer { if owned { Darwin.close(fd) } }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            path.withCString { source in
                withUnsafeMutableBytes(of: &address.sun_path) { destination in
                    _ = memcpy(destination.baseAddress!, source, strlen(source) + 1)
                }
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0, listen(fd, 4) == 0 else { throw POSIXError(.EIO) }
            acceptor = try NectoSocketAcceptor(descriptor: fd)
            owned = false
        }

        func close() {
            acceptor.close()
            unlink(path)
        }
    }

    /// An app on the device: answers the handshake as [app] on every session it gets.
    private actor Peer {
        let app: String
        var sessions: [NectoMessageSession] = []
        var tasks: [Task<Void, Never>] = []
        var count: Int { sessions.count }

        init(app: String) { self.app = app }

        func serve(_ incoming: AsyncThrowingStream<NectoMessageSession, any Error>) {
            let app = app
            tasks.append(Task {
                do {
                    for try await session in incoming {
                        self.add(session)
                        try await session.send(NectoHandshakeHello(appBundleID: app, appName: "Fixture",
                            appVersion: "1", deviceName: "Fixture", sdkVersion: "1", simulatorID: "ios-probe"))
                        _ = try? await session.receive(NectoHandshakeAck.self)
                    }
                } catch {}
            })
        }

        private func add(_ session: NectoMessageSession) { sessions.append(session) }
        func disconnect() { sessions.last?.close() }
        func stop() { tasks.forEach { $0.cancel() }; sessions.forEach { $0.close() } }
    }

    /// ADB as the centre sees it: devices, the apps found on each, and forwards that
    /// land on the [Peer] listening under the forwarded name.
    private actor FakeADB: NectoADB {
        var serials: [String] = []
        var apps: [String: [String: String]] = [:]
        var peers: [String: Peer] = [:]
        var forwarded: [String] = []
        var removed: [String] = []
        /// Serials whose next scan fails, as a device that answers late does.
        var failing: Set<String> = []
        private var listeners: [String: UnixListener] = [:]
        private var forwardSerials: [String: String] = [:]

        func set(serials: [String]) { self.serials = serials }
        func set(apps: [String: String], on serial: String) { self.apps[serial] = apps }
        func listen(_ peer: Peer, as name: String) { peers[name] = peer }

        func devices() async throws -> [String] { serials }
        func endpoints(serial: String) async throws -> [String: String] {
            if failing.remove(serial) != nil { throw POSIXError(.ETIMEDOUT) }
            return apps[serial] ?? [:]
        }
        func failOnce(_ serial: String) { failing.insert(serial) }

        func forward(serial: String, socketPath: String, name: String) async throws {
            guard let peer = peers[name] else { throw POSIXError(.ECONNREFUSED) }
            listeners.removeValue(forKey: socketPath)?.close()
            let listener = try UnixListener(path: socketPath)
            listeners[socketPath] = listener
            forwardSerials[socketPath] = serial
            forwarded.append(name)
            await peer.serve(listener.acceptor.sessions)
        }

        func removeForward(serial: String, socketPath: String) async {
            listeners.removeValue(forKey: socketPath)?.close()
            removed.append(socketPath)
        }

        func forwards() async throws -> [(serial: String, socketPath: String)] {
            listeners.keys.map { (forwardSerials[$0] ?? "", $0) }
        }

        /// What a restarted adb server does: every forward is gone.
        func restartServer() { listeners.values.forEach { $0.close() }; listeners.removeAll() }

        func stop() { restartServer() }
    }

    private func name(_ seed: Character) -> String { "necto." + String(repeating: seed, count: 64) }

    /// A loopback port nobody listens on, so the simulator probe finds nothing.
    private func unusedPort() throws -> UInt16 {
        let listener = NectoDeviceListener(port: 0)
        try listener.start()
        defer { listener.stop() }
        return listener.port
    }

    private func center(_ adb: FakeADB, port: UInt16? = nil) throws -> NectoConnectionCenter {
        NectoConnectionCenter(port: try port ?? unusedPort(), probeInterval: .milliseconds(30),
                              deviceEvents: { AsyncThrowingStream { $0.finish() } }, adb: adb)
    }

    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !(await condition()) {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("A forwarded socket must be owned by this user inside a private directory")
    func privatePath() async throws {
        let directory = "/tmp/necto-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let listener = try UnixListener(path: directory + "/adb.sock")
        defer { listener.close() }
        let endpoint = NectoConnectionCenter.AndroidEndpoint(serial: "phone", socketPath: listener.path, appBundleID: "dev.necto.fixture")
        let session = try await endpoint.connect()
        session.close()
        try #require(chmod(directory, 0o755) == 0)
        await #expect(throws: POSIXError.self) { try await endpoint.connect() }
        try #require(chmod(directory, 0o700) == 0)
        let link = directory + "/alias.sock"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: listener.path)
        let alias = NectoConnectionCenter.AndroidEndpoint(serial: "phone", socketPath: link, appBundleID: "dev.necto.fixture")
        await #expect(throws: POSIXError.self) { try await alias.connect() }
    }

    @Test("Every Necto app on a device is found, forwarded and connected")
    func discoversEveryApp() async throws {
        let adb = FakeADB()
        let one = Peer(app: "dev.necto.one"), two = Peer(app: "dev.necto.two")
        await adb.listen(one, as: name("a"))
        await adb.listen(two, as: name("b"))
        await adb.set(serials: ["R3CY70P3F4H"])
        await adb.set(apps: ["dev.necto.one": name("a"), "dev.necto.two": name("b")], on: "R3CY70P3F4H")
        let center = try center(adb)
        await center.start()
        defer { Task { await center.stop(); await one.stop(); await two.stop(); await adb.stop() } }

        try await wait { await center.connectedApps.count == 2 }
        let apps = await center.connectedApps
        #expect(Set(apps.map(\.appBundleID)) == ["dev.necto.one", "dev.necto.two"])
        #expect(Set(apps.map(\.target.deviceID)) == ["android:R3CY70P3F4H"])
        #expect(Set(apps.map(\.connection)) == [.androidDevice])
    }

    @Test("An app that restarts under a new name is forwarded to it again")
    func followsANewName() async throws {
        let adb = FakeADB()
        let before = Peer(app: "dev.necto.one"), after = Peer(app: "dev.necto.one")
        await adb.listen(before, as: name("a"))
        await adb.listen(after, as: name("c"))
        await adb.set(serials: ["phone"])
        await adb.set(apps: ["dev.necto.one": name("a")], on: "phone")
        let center = try center(adb)
        await center.start()
        defer { Task { await center.stop(); await before.stop(); await after.stop(); await adb.stop() } }

        try await wait { await center.connectedApps.count == 1 }
        await adb.set(apps: ["dev.necto.one": name("c")], on: "phone")
        await before.stop()
        try await wait { await after.count >= 1 }
        try await wait { await center.connectedApps.count == 1 }
        #expect(await adb.forwarded == [name("a"), name("c")])
    }

    @Test("An app or a device that goes away is let go, with its forward")
    func letsGo() async throws {
        let adb = FakeADB()
        let one = Peer(app: "dev.necto.one"), two = Peer(app: "dev.necto.two")
        await adb.listen(one, as: name("a"))
        await adb.listen(two, as: name("b"))
        await adb.set(serials: ["phone"])
        await adb.set(apps: ["dev.necto.one": name("a"), "dev.necto.two": name("b")], on: "phone")
        let center = try center(adb)
        await center.start()
        defer { Task { await center.stop(); await one.stop(); await two.stop(); await adb.stop() } }

        try await wait { await center.connectedApps.count == 2 }
        await adb.set(apps: ["dev.necto.two": name("b")], on: "phone")
        try await wait { await center.connectedApps.map(\.appBundleID) == ["dev.necto.two"] }
        #expect(await adb.removed.count == 1)

        await adb.set(serials: [])
        try await wait { await center.connectedApps.isEmpty }
        #expect(await adb.removed.count == 2)
    }

    @Test("A different app cannot claim another app's forward")
    func wrongApplication() async throws {
        let adb = FakeADB()
        let impostor = Peer(app: "dev.other.app")
        await adb.listen(impostor, as: name("a"))
        await adb.set(serials: ["phone"])
        await adb.set(apps: ["dev.necto.fixture": name("a")], on: "phone")
        let center = try center(adb)
        await center.start()
        defer { Task { await center.stop(); await impostor.stop(); await adb.stop() } }

        try await wait { await impostor.count >= 2 }
        #expect(await center.connectedApps.isEmpty)
    }

    @Test("Android and iOS reconnect independently using their original message contract")
    func mixedPlatforms() async throws {
        let ios = NectoDeviceListener(port: 0)
        try ios.start()
        defer { ios.stop() }
        let adb = FakeADB()
        let androidPeer = Peer(app: "dev.necto.fixture"), iosPeer = Peer(app: "dev.necto.fixture")
        await adb.listen(androidPeer, as: name("a"))
        await adb.set(serials: ["emulator-5554"])
        await adb.set(apps: ["dev.necto.fixture": name("a")], on: "emulator-5554")
        await iosPeer.serve(ios.sessions())
        let center = try center(adb, port: ios.port)
        await center.start()
        defer { Task { await center.stop(); await androidPeer.stop(); await iosPeer.stop(); await adb.stop() } }

        try await wait { await center.connectedApps.count == 2 }
        #expect(Set(await center.connectedApps.map(\.connection)) == [.simulator, .androidEmulator])
        await androidPeer.disconnect()
        try await wait { await androidPeer.count == 2 }
        #expect(await iosPeer.count == 1)
        await iosPeer.disconnect()
        try await wait { await iosPeer.count == 2 }
        try await wait { await center.connectedApps.count == 2 }
        #expect(await androidPeer.count == 2)
    }

    @Test("A device that answers late keeps its apps connected")
    func keepsAppsOnALateAnswer() async throws {
        let adb = FakeADB()
        let one = Peer(app: "dev.necto.one")
        await adb.listen(one, as: name("a"))
        await adb.set(serials: ["phone"])
        await adb.set(apps: ["dev.necto.one": name("a")], on: "phone")
        let center = try center(adb)
        await center.start()
        defer { Task { await center.stop(); await one.stop(); await adb.stop() } }

        try await wait { await center.connectedApps.count == 1 }
        await adb.failOnce("phone")
        try await wait { await adb.failing.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await center.connectedApps.count == 1)
        #expect(await adb.removed.isEmpty)
        #expect(await one.count == 1)
    }

    @Test("Forwards a restarted adb server forgot are made again")
    func reforwardsAfterAServerRestart() async throws {
        let adb = FakeADB()
        let one = Peer(app: "dev.necto.one")
        await adb.listen(one, as: name("a"))
        await adb.set(serials: ["phone"])
        await adb.set(apps: ["dev.necto.one": name("a")], on: "phone")
        let center = try center(adb)
        await center.start()
        defer { Task { await center.stop(); await one.stop(); await adb.stop() } }

        try await wait { await center.connectedApps.count == 1 }
        await adb.restartServer()
        await one.disconnect()
        try await wait { await adb.forwarded.count == 2 }
        try await wait { await one.count == 2 }
        try await wait { await center.connectedApps.count == 1 }
    }

    @Test("Only a run whose process is gone counts as abandoned")
    func abandonedDirectories() {
        let prefix = NectoConnectionCenter.androidSocketDirectoryPrefix
        // pid_max on macOS is 99999, so this pid cannot be running.
        #expect(NectoConnectionCenter.abandonedAndroidSocketDirectory(holding: prefix + "999999.abc123/1.sock")
            == prefix + "999999.abc123")
        #expect(NectoConnectionCenter.abandonedAndroidSocketDirectory(holding: prefix + "\(getpid()).abc123/1.sock") == nil)
        // launchd: running, and owned by another user.
        #expect(NectoConnectionCenter.abandonedAndroidSocketDirectory(holding: prefix + "1.abc123/1.sock") == nil)
        #expect(NectoConnectionCenter.abandonedAndroidSocketDirectory(holding: "/tmp/other/1.sock") == nil)
        #expect(NectoConnectionCenter.abandonedAndroidSocketDirectory(holding: prefix + "abc123/1.sock") == nil)
        // A forward anyone could add must not lead the cleanup out of Necto's directory.
        for escape in ["999999.abc123/../../../Users/x/1.sock", "999999.abc123/1.sock/../..", "999999.abc123/x/1.sock",
                       "999999.abc12/1.sock", "999999.abc123/1.socket"] {
            #expect(NectoConnectionCenter.abandonedAndroidSocketDirectory(holding: prefix + escape) == nil)
        }
    }

    /// A stand-in adb: answers by the command it gets, as written in [script].
    private func fakeADB(_ script: String) throws -> (NectoADBClient, String) {
        let directory = "/tmp/necto-fake-adb-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
        let path = directory + "/adb"
        FileManager.default.createFile(atPath: path, contents: Data(("#!/bin/sh\n" + script).utf8),
                                       attributes: [.posixPermissions: 0o755])
        return (NectoADBClient(executable: path), directory)
    }

    @Test("adb is asked on localhost, and a failed command is not an empty answer")
    func adbProcessWiring() async throws {
        let (failing, first) = try fakeADB("""
            [ "$1 $2" = "-H localhost" ] || exit 9
            exit 1
            """)
        defer { try? FileManager.default.removeItem(atPath: first) }
        await #expect(throws: POSIXError.self) { _ = try await failing.devices() }
        await #expect(throws: POSIXError.self) { _ = try await failing.endpoints(serial: "phone") }

        let good = name("a").replacingOccurrences(of: "a", with: "0")
        let (cut, second) = try fakeADB("""
            case "$*" in *shell*) echo "dev.necto.one \(good)";; esac
            """)
        defer { try? FileManager.default.removeItem(atPath: second) }
        // A scan that stopped before its marker is incomplete, not a device without apps.
        await #expect(throws: POSIXError.self) { _ = try await cut.endpoints(serial: "phone") }

        let (whole, third) = try fakeADB("""
            case "$*" in *shell*) echo "dev.necto.one \(good)"; echo \(NectoADBClient.scanDone);; esac
            """)
        defer { try? FileManager.default.removeItem(atPath: third) }
        #expect(try await whole.endpoints(serial: "phone") == ["dev.necto.one": good])
    }

    @Test("adb output is read strictly: only authorized devices and well-formed names")
    func parsesADB() {
        #expect(NectoADBClient.authorizedSerials("""
            List of devices attached
            R3CY70P3F4H\tdevice
            emulator-5554\toffline
            ZY22\tunauthorized

            """) == ["R3CY70P3F4H"])
        let good = name("a").replacingOccurrences(of: "a", with: "0")
        #expect(NectoADBClient.endpoints("""
            dev.necto.one \(good)
            dev.necto.two necto.short
            bad;name \(good)
            dev.necto.three \(good) extra
            """) == ["dev.necto.one": good])
        // An app writing a second line into its own file cannot file a name under
        // another package, whichever line ending it uses.
        #expect(NectoADBClient.endpoints("dev.evil.app \(good)\ndev.victim.app \(good)\ndev.evil.app \(good)\n")
            == ["dev.victim.app": good])
        #expect(NectoADBClient.endpoints("dev.evil.app \(good)\rdev.victim.app \(good)\n").isEmpty)
        #expect(!NectoADBClient.isEndpointName(good + "\n"))
        #expect(!NectoADBClient.isPackageName("a.b\n"))
        #expect(!NectoADBClient.isPackageName("a.b; rm -rf /"))
        let forwards = NectoADBClient.forwards("""
            phone localfilesystem:/tmp/x/1.sock localabstract:necto.abc
            phone tcp:5000 localabstract:other
            """)
        #expect(forwards.map(\.socketPath) == ["/tmp/x/1.sock"])
        #expect(!NectoADBClient.isEndpointName("necto.\(String(repeating: "A", count: 64))"))
    }

    @Test("adb is found in the Android SDK's usual places, or not at all")
    func locatesADB() throws {
        let sdk = "/tmp/necto-sdk-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: sdk + "/platform-tools", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: sdk) }
        let adb = sdk + "/platform-tools/adb"
        FileManager.default.createFile(atPath: adb, contents: Data(), attributes: [.posixPermissions: 0o755])
        #expect(NectoADBClient.locate(environment: ["ANDROID_HOME": sdk], home: "/nonexistent") == adb)
        #expect(NectoADBClient.locate(environment: ["ANDROID_SDK_ROOT": sdk], home: "/nonexistent") == adb)
        #expect(NectoADBClient.locate(environment: [:], home: "/nonexistent") == nil)
    }
}
