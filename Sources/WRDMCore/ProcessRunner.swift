import Darwin
import Foundation

// ProcessExecutionState distinguishes a clean exit from a process trapped below user space.
public enum ProcessExecutionState: String, Codable, Equatable, Sendable {
    case exited
    case running
    case uninterruptibleKernelWait
    case unknown
}

// ProcessSnapshot records bounded process-tree evidence without command arguments or environment data.
public struct ProcessSnapshot: Codable, Equatable, Sendable {
    public var processIdentifier: Int32
    public var parentProcessIdentifier: Int32
    public var state: String

    // init creates one sanitized process-state observation.
    public init(processIdentifier: Int32, parentProcessIdentifier: Int32, state: String) {
        self.processIdentifier = processIdentifier
        self.parentProcessIdentifier = parentProcessIdentifier
        self.state = state
    }
}

// ProcessResult captures bounded command output and the evidence needed for safe recovery decisions.
public struct ProcessResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var processIdentifier: Int32?
    public var durationSeconds: Double
    public var sentSignals: [Int32]
    public var stillRunning: Bool
    public var executionState: ProcessExecutionState
    public var descendants: [ProcessSnapshot]

    // init keeps adapters and deterministic tests explicit while providing safe empty evidence defaults.
    public init(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        timedOut: Bool,
        processIdentifier: Int32? = nil,
        durationSeconds: Double = 0,
        sentSignals: [Int32] = [],
        stillRunning: Bool = false,
        executionState: ProcessExecutionState = .exited,
        descendants: [ProcessSnapshot] = []
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.processIdentifier = processIdentifier
        self.durationSeconds = durationSeconds
        self.sentSignals = sentSignals
        self.stillRunning = stillRunning
        self.executionState = executionState
        self.descendants = descendants
    }

    // requiresRestart identifies the kernel-wait condition that user-space signals cannot repair.
    public var requiresRestart: Bool {
        executionState == .uninterruptibleKernelWait
    }
}

// ProcessExecuting makes every command boundary replaceable by deterministic test adapters.
public protocol ProcessExecuting: Sendable {
    func run(
        _ executable: String,
        arguments: [String],
        input: Data?,
        timeout: TimeInterval,
        environment: [String: String]?
    ) throws -> ProcessResult
}

// SystemProcessExecutor delegates protocol-based adapters to the hardened process runner.
public struct SystemProcessExecutor: ProcessExecuting {
    public init() {}

    // run forwards one bounded command without changing its policy inputs.
    public func run(
        _ executable: String,
        arguments: [String] = [],
        input: Data? = nil,
        timeout: TimeInterval = 15,
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
        try ProcessRunner.run(executable, arguments: arguments, input: input, timeout: timeout, environment: environment)
    }
}

// ProcessRunner is the only direct Foundation Process boundary used by the native runtime.
public enum ProcessRunner {
    public static func run(
        _ executable: String,
        arguments: [String] = [],
        input: Data? = nil,
        timeout: TimeInterval = 15,
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
        let startedAt = Date()
        let process = Process()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wrdm-process-\(UUID().uuidString)", isDirectory: true)
        try SecureFileAccess.ensureDirectory(temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr")
        try SecureFileAccess.writeAtomically(Data(), to: stdoutURL)
        try SecureFileAccess.writeAtomically(Data(), to: stderrURL)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        if input != nil {
            process.standardInput = stdin
        }
        process.environment = environment ?? minimalEnvironment()

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        try process.run()
        let processIdentifier = process.processIdentifier
        if let input {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }

        var sentSignals: [Int32] = []
        let timedOut = semaphore.wait(timeout: .now() + timeout) == .timedOut
        var knownProcessTree: [ProcessSnapshot] = []
        if timedOut {
            // Capture descendants before signals because children may be reparented when the root exits.
            knownProcessTree = processTree(rootProcessIdentifier: processIdentifier)
            process.terminate()
            sentSignals.append(SIGTERM)
            _ = semaphore.wait(timeout: .now() + 2)
            if process.isRunning {
                kill(processIdentifier, SIGKILL)
                sentSignals.append(SIGKILL)
                _ = semaphore.wait(timeout: .now() + 2)
            }
        }

        let snapshots = timedOut ? survivingProcessTree(rootProcessIdentifier: processIdentifier, previouslyObserved: knownProcessTree) : []
        let rootAlive = processIsAlive(processIdentifier)
        let livingDescendants = snapshots.filter { processIsAlive($0.processIdentifier) }
        let stillRunning = rootAlive || !livingDescendants.isEmpty
        let executionState = classify(stillRunning: stillRunning, snapshots: snapshots)

        try? stdout.synchronize()
        try? stderr.synchronize()
        let outputData = (try? Data(contentsOf: stdoutURL)) ?? Data()
        let errorData = (try? Data(contentsOf: stderrURL)) ?? Data()
        return ProcessResult(
            exitCode: timedOut ? 124 : process.terminationStatus,
            stdout: String(decoding: outputData, as: UTF8.self),
            stderr: String(decoding: errorData, as: UTF8.self),
            timedOut: timedOut,
            processIdentifier: processIdentifier,
            durationSeconds: Date().timeIntervalSince(startedAt),
            sentSignals: sentSignals,
            stillRunning: stillRunning,
            executionState: executionState,
            descendants: livingDescendants
        )
    }

    // classify maps process snapshots to the terminal safety state used by mount recovery.
    public static func classify(stillRunning: Bool, snapshots: [ProcessSnapshot]) -> ProcessExecutionState {
        guard stillRunning else { return .exited }
        if snapshots.contains(where: { $0.state.uppercased().hasPrefix("U") }) {
            return .uninterruptibleKernelWait
        }
        return snapshots.isEmpty ? .unknown : .running
    }

    // isProcessAlive lets recovery recheck a previously surviving bounded command before another mutation.
    public static func isProcessAlive(_ processIdentifier: Int32) -> Bool {
        processIsAlive(processIdentifier)
    }

    // processTree reads sanitized pid, parent, and state fields and selects the complete descendant tree.
    private static func processTree(rootProcessIdentifier: Int32) -> [ProcessSnapshot] {
        let all = processList()
        var selected = Set<Int32>([rootProcessIdentifier])
        var changed = true
        while changed {
            changed = false
            for snapshot in all where selected.contains(snapshot.parentProcessIdentifier) && !selected.contains(snapshot.processIdentifier) {
                selected.insert(snapshot.processIdentifier)
                changed = true
            }
        }
        return all.filter { selected.contains($0.processIdentifier) }
    }

    // survivingProcessTree retains descendants that were reparented after their timed-out root exited.
    private static func survivingProcessTree(
        rootProcessIdentifier: Int32,
        previouslyObserved: [ProcessSnapshot]
    ) -> [ProcessSnapshot] {
        let all = processList()
        return correlatedProcessTree(
            rootProcessIdentifier: rootProcessIdentifier,
            previouslyObserved: previouslyObserved,
            current: all
        )
    }

    // correlatedProcessTree keeps previously known children even after the kernel reparents them.
    public static func correlatedProcessTree(
        rootProcessIdentifier: Int32,
        previouslyObserved: [ProcessSnapshot],
        current: [ProcessSnapshot]
    ) -> [ProcessSnapshot] {
        var selected = Set(previouslyObserved.map(\.processIdentifier))
        selected.insert(rootProcessIdentifier)
        var changed = true
        while changed {
            changed = false
            for snapshot in current where selected.contains(snapshot.parentProcessIdentifier) && !selected.contains(snapshot.processIdentifier) {
                selected.insert(snapshot.processIdentifier)
                changed = true
            }
        }
        return current.filter { selected.contains($0.processIdentifier) }
    }

    // processList parses the sanitized system process table for tree correlation.
    private static func processList() -> [ProcessSnapshot] {
        guard let output = processListOutput() else { return [] }
        return output.split(separator: "\n").compactMap { line -> ProcessSnapshot? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3,
                  let processIdentifier = Int32(fields[0]),
                  let parentProcessIdentifier = Int32(fields[1]) else { return nil }
            return ProcessSnapshot(
                processIdentifier: processIdentifier,
                parentProcessIdentifier: parentProcessIdentifier,
                state: String(fields[2])
            )
        }
    }

    // processListOutput uses a separate bounded system command without entering ProcessRunner recursively.
    private static func processListOutput() -> String? {
        let process = Process()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wrdm-ps-\(UUID().uuidString)")
        guard (try? SecureFileAccess.writeAtomically(Data(), to: file)) != nil,
              let output = try? FileHandle(forWritingTo: file) else { return nil }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: file)
        }
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,state="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.environment = minimalEnvironment()
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        guard (try? process.run()) != nil else { return nil }
        if semaphore.wait(timeout: .now() + 1) == .timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 0.25)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        try? output.synchronize()
        guard let data = try? Data(contentsOf: file) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // processIsAlive treats permission-denied probes as evidence that the process still exists.
    private static func processIsAlive(_ processIdentifier: Int32) -> Bool {
        guard processIdentifier > 0 else { return false }
        errno = 0
        return kill(processIdentifier, 0) == 0 || errno == EPERM
    }

    // minimalEnvironment prevents unrelated login-session secrets reaching child diagnostics.
    public static func minimalEnvironment() -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        var environment: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LANG": source["LANG"] ?? "en_US.UTF-8",
        ]
        for key in ["USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK"] {
            if let value = source[key] {
                environment[key] = value
            }
        }
        return environment
    }

    // sanitizeCurrentProcessEnvironment removes inherited secret classes before agent work begins.
    public static func sanitizeCurrentProcessEnvironment() {
        for key in ProcessInfo.processInfo.environment.keys {
            if isSensitiveEnvironmentVariable(key) {
                unsetenv(key)
            }
        }
    }

    // reexecCurrentProcessWithMinimalEnvironment replaces the initial process image so OS inspection cannot retain inherited secrets.
    public static func reexecCurrentProcessWithMinimalEnvironment() {
        let marker = "WRDM_ENV_SANITIZED"
        guard ProcessInfo.processInfo.environment[marker] != "1" else {
            sanitizeCurrentProcessEnvironment()
            return
        }
        var environment = minimalEnvironment()
        environment[marker] = "1"
        let arguments: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) } + [nil]
        let variables: [UnsafeMutablePointer<CChar>?] = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            // Release duplicated C strings only when execve returns with an error.
            for case let pointer? in arguments { Darwin.free(UnsafeMutableRawPointer(pointer)) }
            for case let pointer? in variables { Darwin.free(UnsafeMutableRawPointer(pointer)) }
        }
        arguments.withUnsafeBufferPointer { argumentBuffer in
            variables.withUnsafeBufferPointer { variableBuffer in
                _ = execve(
                    CommandLine.arguments[0],
                    UnsafeMutablePointer(mutating: argumentBuffer.baseAddress!),
                    UnsafeMutablePointer(mutating: variableBuffer.baseAddress!)
                )
            }
        }
        // If replacement fails, still remove secrets from the process-visible runtime environment.
        sanitizeCurrentProcessEnvironment()
    }

    // isSensitiveEnvironmentVariable centralizes conservative secret-name matching for tests and entrypoints.
    static func isSensitiveEnvironmentVariable(_ name: String) -> Bool {
        let protectedNames = ["TOKEN", "SECRET", "PASSWORD", "PRIVATE", "CREDENTIAL", "API_KEY", "BW_SESSION"]
        return protectedNames.contains { name.uppercased().contains($0) }
    }
}
