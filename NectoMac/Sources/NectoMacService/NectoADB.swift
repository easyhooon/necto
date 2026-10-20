//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import Foundation

/// What the connection centre needs from ADB. ``NectoADBClient`` runs the adb tool; tests
/// supply their own.
protocol NectoADB: Sendable {
    /// Authorized devices on a USB cable and real local emulators. Wireless ADB is left out.
    func devices() async throws -> [String]
    /// The running apps on [serial] that carry a Necto socket, by package, with its name.
    func endpoints(serial: String) async throws -> [String: String]
    /// Forwards the Unix socket at [socketPath] to the device's abstract socket [name].
    func forward(serial: String, socketPath: String, name: String) async throws
    func removeForward(serial: String, socketPath: String) async
    /// Removes every forward whose local socket starts with [prefix], such as those an
    /// earlier run left behind.
    func removeForwards(prefix: String) async
}

/// Runs the adb tool from the Android SDK against the local adb server.
///
/// An Android app's Necto socket is an abstract socket under a random name that only
/// `adb shell run-as` can read, which needs a debuggable app. Necto reads the name,
/// forwards a private Unix socket to it, and connects there.
actor NectoADBClient: NectoADB {
    private let executable: String
    private var serverStarted = false
    /// Whether a serial is on a USB cable or is a real emulator. A serial keeps its
    /// transport while it stays listed.
    private var local: [String: Bool] = [:]

    init(executable: String) {
        self.executable = executable
    }

    /// The adb in the Android SDK, if one is installed. An app started from the Finder
    /// does not inherit the shell's PATH, so the SDK's usual places are checked instead.
    static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = userHome
    ) -> String? {
        let roots = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"], home + "/Library/Android/sdk"]
        return roots.compactMap { $0 }.filter { !$0.isEmpty }
            .map { $0 + "/platform-tools/adb" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The account's own home: NSHomeDirectory follows CFFIXED_USER_HOME, which a
    /// separate Necto sets for its settings while the SDK stays where it is installed.
    private static var userHome: String {
        getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    }

    func devices() async throws -> [String] {
        if !serverStarted {
            // Necto manages its Android connections itself, so it starts the server when
            // none is running. It leaves it running on quit: other tools share it.
            _ = try await adb(["start-server"], timeoutMilliseconds: 10_000)
            serverStarted = true
        }
        let listed = Self.authorizedSerials(try await adb(["devices"]))
        local = local.filter { listed.contains($0.key) }
        var result: [String] = []
        for serial in listed {
            if local[serial] == nil { local[serial] = try await isLocal(serial) }
            if local[serial] == true { result.append(serial) }
        }
        return result
    }

    func endpoints(serial: String) async throws -> [String: String] {
        Self.endpoints(try await adb(["-s", serial, "shell", Self.endpointScript], timeoutMilliseconds: 10_000))
    }

    func forward(serial: String, socketPath: String, name: String) async throws {
        guard Self.isEndpointName(name) else { throw POSIXError(.EINVAL) }
        let output = try await NectoProcessRunner.run(
            executable, arguments: Self.server + ["-s", serial, "forward", "localfilesystem:" + socketPath, "localabstract:" + name],
            environment: Self.environment, timeoutMilliseconds: 5_000
        )
        guard output.exitCode == 0 else { throw POSIXError(.EIO) }
    }

    func removeForward(serial: String, socketPath: String) async {
        _ = try? await adb(["-s", serial, "forward", "--remove", "localfilesystem:" + socketPath])
    }

    func removeForwards(prefix: String) async {
        guard let list = try? await adb(["forward", "--list"]) else { return }
        for line in list.split(separator: "\n") {
            let fields = line.split(separator: " ").map(String.init)
            guard fields.count == 3, fields[1].hasPrefix("localfilesystem:" + prefix) else { continue }
            await removeForward(serial: fields[0], socketPath: String(fields[1].dropFirst("localfilesystem:".count)))
        }
    }

    /// A cable or a real emulator: wireless ADB reaches the phone from the network, and
    /// an emulator serial is only an emulator when the device says so.
    private func isLocal(_ serial: String) async throws -> Bool {
        if serial.range(of: "^emulator-[0-9]+$", options: .regularExpression) != nil {
            return try await adb(["-s", serial, "shell", "getprop", "ro.kernel.qemu"])
                .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        }
        return try await adb(["-s", serial, "get-devpath"]).hasPrefix("usb:")
    }

    private func adb(_ arguments: [String], timeoutMilliseconds: Int = 5_000) async throws -> String {
        let output = try await NectoProcessRunner.run(
            executable, arguments: Self.server + arguments, environment: Self.environment,
            timeoutMilliseconds: timeoutMilliseconds, maximumOutputBytes: 1_048_576
        )
        return String(decoding: output.stdout, as: UTF8.self)
    }

    /// The server on this Mac, never one named by the environment: that could be a server
    /// on another machine.
    private static let server = ["-H", "127.0.0.1", "-P", "5037"]

    private static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["ADB_SERVER_SOCKET", "ANDROID_ADB_SERVER_ADDRESS", "ANDROID_ADB_SERVER_PORT"] {
            environment.removeValue(forKey: key)
        }
        return environment
    }

    /// Asks only running third-party apps, since only a running app listens. One shell
    /// for every app keeps a scan near a second even with hundreds installed. The script
    /// is fixed: nothing from the host is put into it.
    static let endpointScript = #"k=" $(pm list packages -3 | cut -d: -f2 | tr '\n' ' ') "; "#
        + #"for p in $(ps -A -o NAME= | cut -d: -f1 | sort -u); do case "$k" in *" $p "*) "#
        + #"e=$(run-as "$p" cat no_backup/necto-endpoint 2>/dev/null) && echo "$p $e";; esac; done"#

    static func authorizedSerials(_ output: String) -> [String] {
        output.split(separator: "\n").dropFirst().compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count == 2 && fields[1] == "device" ? String(fields[0]) : nil
        }
    }

    /// Lines of `<package> <name>`. Both come from the device, so both are checked.
    static func endpoints(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ").map(String.init)
            guard fields.count == 2, isPackageName(fields[0]), isEndpointName(fields[1]) else { continue }
            result[fields[0]] = fields[1]
        }
        return result
    }

    static func isPackageName(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$", options: .regularExpression) != nil
    }

    static func isEndpointName(_ value: String) -> Bool {
        value.range(of: "^necto\\.[a-f0-9]{64}$", options: .regularExpression) != nil
    }
}
