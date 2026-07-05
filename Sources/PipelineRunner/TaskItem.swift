import Foundation
import Observation

@MainActor
@Observable
public final class TaskItem {
    public enum TaskItemError: Error, CustomStringConvertible {
        case notConfigured
        case launchFailed(String)

        public var description: String {
            switch self {
            case .notConfigured: return "TaskItem has no Process to launch — call createTask() first."
            case .launchFailed(let m): return "TaskItem launch failed: \(m)"
            }
        }
    }

    public let functionName: String
    public var path: String
    public private(set) var argsArray: [String] = []
    public private(set) var environmentOverrides: [String: String] = [:]
    public private(set) var process: Process?
    public private(set) var stderrPipe: Pipe?
    public private(set) var lastTerminationStatus: Int32?
    public private(set) var lastTerminationReason: Process.TerminationReason?

    public init(path: String, functionName: String) {
        self.path = path
        self.functionName = functionName
    }

    public func addArgument(_ arg: String) {
        argsArray.append(arg)
    }

    public func addArgument<T: Numeric>(_ number: T) {
        argsArray.append("\(number)")
    }

    public func setEnvironment(_ key: String, value: String) {
        environmentOverrides[key] = value
    }

    public func setEnvironment(_ overrides: [String: String]) {
        environmentOverrides.merge(overrides) { _, new in new }
    }

    public func quotedPath() -> String {
        return path
    }

    public func argsString() -> String {
        argsArray.map { arg in
            arg.contains(" ") ? "\"\(arg)\"" : arg
        }.joined(separator: " ")
    }

    public func createTask() {
        lastTerminationStatus = nil
        lastTerminationReason = nil

        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = argsArray
        if !environmentOverrides.isEmpty {
            var env = ProcessInfo.processInfo.environment
            env.merge(environmentOverrides) { _, new in new }
            task.environment = env
        }

        task.terminationHandler = { [weak self] terminated in
            let pid = terminated.processIdentifier
            let status = terminated.terminationStatus
            let reason = terminated.terminationReason
            Task { @MainActor [weak self] in
                guard let self else { return }
                print("TaskItem PID=\(pid) - \(self.path) terminationHandler status=\(status) reason=\(reason.rawValue)")
                self.lastTerminationStatus = status
                self.lastTerminationReason = reason
                self.process = nil
            }
        }

        self.process = task
    }

    public func start() throws {
        guard let task = process else {
            throw TaskItemError.notConfigured
        }
        do {
            try task.run()
            print("TaskItem - Launched Process PID=\(task.processIdentifier), \(path) \(argsString())")
        } catch {
            throw TaskItemError.launchFailed("\(error)")
        }
    }

    public func terminate() {
        guard let task = process, task.isRunning else {
            stderrPipe?.fileHandleForReading.readabilityHandler = nil
            stderrPipe = nil
            process = nil
            return
        }
        task.terminate()
        let deadline = Date().addingTimeInterval(2.0)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if task.isRunning {
            kill(task.processIdentifier, SIGKILL)
        }
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
        process = nil
    }

    public func taskInfoString() -> String {
        let pid = process?.processIdentifier ?? 0
        let runningFlag = (process?.isRunning ?? false) ? 1 : 0
        return "\(functionName) -  process ID = \(pid) -  isRunning = \(runningFlag)\n\n\"\(path)\" \(argsString())\n\n"
    }
}
