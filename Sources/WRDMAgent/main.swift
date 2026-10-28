import Foundation
import Darwin
import WRDMCore
import UserNotifications

// The agent executable owns continuous monitoring independently from the menu-bar UI.
@main
struct WRDMAgentMain {
    static func main() async {
        // Replace the inherited launch-session environment before the long-running agent starts.
        ProcessRunner.reexecCurrentProcessWithMinimalEnvironment()
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--enable-update-notifications" {
            // The agent owns update notices, so its own bundle must request notification consent.
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
            return
        }
        if arguments.first == "--transfer-worker" {
            await runTransferWorker(arguments: arguments)
            return
        }
        let runtime = AgentRuntime()
        if CommandLine.arguments.contains("--once") {
            _ = await runtime.runOneCycle()
            return
        }
        await runtime.run()
    }

    // runTransferWorker executes exactly one persisted transfer job and exits for the parent agent to monitor.
    private static func runTransferWorker(arguments: [String]) async {
        guard arguments.count >= 2,
              let jobID = UUID(uuidString: arguments[1]) else {
            fputs("Missing or invalid transfer job identifier.\n", stderr)
            exit(EX_USAGE)
        }
        let homeDirectory = value(after: "--home", in: arguments)
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let code = await TransferService.runWorker(jobID: jobID, paths: AppPaths(homeDirectory: homeDirectory))
        exit(code)
    }

    // value reads a single command-line option without allowing ambiguous repeated options.
    private static func value(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option),
              arguments.indices.contains(arguments.index(after: index)) else {
            return nil
        }
        return arguments[arguments.index(after: index)]
    }
}
