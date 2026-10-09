import Foundation
import AppKit
import CryptoKit
import Darwin

/// Read-only checks; never sends a prompt, starts a turn, or resumes a task.
@main
struct CLICompatibility {
    static func main() {
        let mode = CommandLine.arguments.dropFirst().first ?? "--check"
        guard ["--identity", "--check"].contains(mode) else {
            fputs("Usage: check-cli-compatibility.sh [--identity|--check]\n", stderr)
            exit(2)
        }
        var result: [String: Any] = [:]
        do {
            let defaults = UserDefaults(suiteName: "com.codexkeeper.app")!
            let bundles = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.openai.codex" }.compactMap(\.bundleURL)
            let binary = try CodexLocator.binary(environment: ProcessInfo.processInfo.environment,
                userHome: FileManager.default.homeDirectoryForCurrentUser, runningBundles: bundles,
                fallbackPath: defaults.string(forKey: CodexLocator.fallbackPathKey))
            let version = try cliVersion(binary)
            result["identity"] = ["binary": binary.path, "resolvedBinary": binary.resolvingSymlinksInPath().path,
                "version": version, "sha256": SHA256.hash(data: try Data(contentsOf: binary, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()]
            result["codexHome"] = CodexEnvironment.home.path
            if mode == "--check" {
                var checks: [String: String] = [:]
                var model = PingModel(model: "gpt-6-luna", reasoningEffort: "low")
                do {
                    let provider = AppServerUsageProvider(makeTransport: { try AppServerClient(binary: binary, usageOnly: true) })
                    defer { AppServerClient.closeAll() }
                    let first = try provider.read(), second = try provider.read()
                    guard first.isFresh(at: Date()), second.isFresh(at: Date()),
                          first.accountID != nil, first.accountID == second.accountID else {
                        throw CodexConnectionError.invalidResponse
                    }
                    checks["accountAndQuota"] = "passed"
                    model = try provider.pingModel()
                    checks["pingModel"] = "passed"
                } catch {
                    checks["readOnlyAPI"] = "failed"
                    result["readFailure"] = UsageReadFailure.describe(error, elapsed: 0).reason
                }
                for shared in [false, true] {
                    do { checks[shared ? "sharedDaemonStartup" : "freshHomeStartup"] = try startup(binary, shared: shared, model: model) ? "passed" : "unconfirmed" }
                    catch { checks[shared ? "sharedDaemonStartup" : "freshHomeStartup"] = "failed" }
                }
                result["checks"] = checks
                result["passed"] = checks.values.allSatisfy { $0 == "passed" }
                result["endToEnd"] = "not_tested_no_prompt_sent"
            }
        } catch {
            result["passed"] = false
            result["failure"] = "identity_or_local_setup_failed"
        }
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
        if result["passed"] as? Bool == false { exit(1) }
    }

    static func cliVersion(_ binary: URL) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = binary; process.arguments = ["--version"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { stop(process) }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10000) }
        guard !process.isRunning, process.terminationStatus == 0 else { throw CodexConnectionError.timeout }
        let version = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard version.hasPrefix("codex-cli ") else { throw CodexConnectionError.invalidResponse }
        return version
    }

    static func startup(_ binary: URL, shared: Bool, model: PingModel) throws -> Bool {
        let fm = FileManager.default
        let ping = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexKeeper/ping")
        let root = fm.temporaryDirectory.appendingPathComponent("keeper-cli-check-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let home = shared ? ping.appendingPathComponent("home") : root.appendingPathComponent("home")
        let work = shared ? ping.appendingPathComponent("work") : root.appendingPathComponent("work")
        defer { if !shared { stopTemporaryDaemon(home) }; try? fm.removeItem(at: root) }
        let config = try PTYPingTransport.configuration(work: work, model: model)
        if !shared {
            try fm.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let authURL = home.appendingPathComponent("auth.json")
            try Data(contentsOf: CodexEnvironment.home.appendingPathComponent("auth.json")).write(to: authURL)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
            try config.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        }
        var master: Int32 = -1, slave: Int32 = -1
        var size = winsize(ws_row: 30, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw CodexConnectionError.ended }
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true), process = Process()
        defer { stop(process); try? terminal.close(); Darwin.close(master) }
        process.executableURL = binary
        process.arguments = ["--no-alt-screen", "-C", work.path]
        if shared {
            // Test today's generated settings without replacing the configuration of the live ping home.
            process.arguments! += config.split(separator: "\n").prefix { !$0.hasPrefix("[") }.filter { !$0.isEmpty }.flatMap { ["-c", String($0)] }
        }
        process.currentDirectoryURL = work
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = home.path; env["TERM"] = "xterm-256color"
        env.removeValue(forKey: "OPENAI_API_KEY"); env.removeValue(forKey: "CODEX_API_KEY")
        process.environment = env
        process.standardInput = terminal; process.standardOutput = terminal; process.standardError = terminal
        try process.run()
        var output = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 100) > 0 {
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(master, &bytes, bytes.count)
                if count > 0 { output.append(contentsOf: bytes.prefix(count)) }
                if output.count > 65536 { output.removeFirst(output.count - 65536) }
            }
            let text = String(decoding: output, as: UTF8.self).replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            if text.contains("incompatible feature settings") || text.contains("Error loading config") { return false }
            let compact = text.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            if compact.contains("AskCodextodoanything"), compact.contains("GPT-6-Luna\(model.reasoningEffort ?? "default")") {
                return shared || !fm.fileExists(atPath: home.appendingPathComponent("app-server-daemon/daemon.pid").path)
            }
        }
        return false
    }

    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    static func stopTemporaryDaemon(_ home: URL) {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("app-server-daemon/daemon.pid")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = object["pid"] as? Int32, pid > 1 else { return }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "command="]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
        let command = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // Only a daemon installed beneath this temporary home belongs to the probe.
        guard command.hasPrefix(home.resolvingSymlinksInPath().path + "/"), command.contains("--managed-daemon") else { return }
        kill(pid, SIGTERM)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while kill(pid, 0) == 0 && ProcessInfo.processInfo.systemUptime < deadline { usleep(10000) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
}
