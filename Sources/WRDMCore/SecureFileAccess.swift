import Darwin
import Foundation

// SecureFileAccess centralizes private permissions, cross-process locks, and atomic replacement.
public enum SecureFileAccess {
    public static let privateDirectoryMode: mode_t = 0o700
    public static let privateFileMode: mode_t = 0o600

    // ensureDirectory creates an app-owned directory and repairs permissive existing modes.
    public static func ensureDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard chmod(directory.path, privateDirectoryMode) == 0 else {
            throw FileAccessError.posix(operation: "chmod directory", code: errno)
        }
    }

    // hardenFile repairs a private file mode when the file already exists.
    public static func hardenFile(_ file: URL) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        guard chmod(file.path, privateFileMode) == 0 else {
            throw FileAccessError.posix(operation: "chmod file", code: errno)
        }
    }

    // withLock serializes one app-owned file operation across app, agent, CLI, and MCP processes.
    public static func withLock<T>(for file: URL, exclusive: Bool = true, _ body: () throws -> T) throws -> T {
        try ensureDirectory(file.deletingLastPathComponent())
        let lockFile = file.appendingPathExtension("lock")
        let descriptor = open(lockFile.path, O_CREAT | O_RDWR, privateFileMode)
        guard descriptor >= 0 else {
            throw FileAccessError.posix(operation: "open lock", code: errno)
        }
        defer { close(descriptor) }
        guard flock(descriptor, exclusive ? LOCK_EX : LOCK_SH) == 0 else {
            throw FileAccessError.posix(operation: "lock file", code: errno)
        }
        defer { flock(descriptor, LOCK_UN) }
        try hardenFile(lockFile)
        return try body()
    }

    // writeAtomically replaces one file with private permissions without exposing partial content.
    public static func writeAtomically(_ data: Data, to file: URL) throws {
        try ensureDirectory(file.deletingLastPathComponent())
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            try hardenFile(temporary)
            guard rename(temporary.path, file.path) == 0 else {
                throw FileAccessError.posix(operation: "replace file", code: errno)
            }
            try hardenFile(file)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

// FileAccessError keeps low-level persistence failures actionable without leaking file content.
public enum FileAccessError: LocalizedError, Equatable {
    case posix(operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .posix(let operation, let code):
            "Secure file operation failed during \(operation) with errno \(code)."
        }
    }
}
