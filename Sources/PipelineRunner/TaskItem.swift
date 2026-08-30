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
    /// Assigned by `TaskPipelineManager.configureTaskPipes()`, which is why
    /// the setter is `internal` rather than `private` — it lives in this
    /// module but a different file/type.
    public internal(set) var stderrPipe: Pipe?
    public private(set) var lastTerminationStatus: Int32?
    public private(set) var lastTerminationReason: Process.TerminationReason?

    /// Called for this task's own diagnostic messages (launch/termination)
    /// and, once `TaskPipelineManager.configureTaskPipes()` wires up
    /// `stderrPipe`, for each line of the subprocess's relayed stderr.
    /// Lets a host app forward everything through its own logging system
    /// without this package needing to know about a concrete log type.
    public var onLog: ((String) -> Void)?

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

        // Always set an explicit environment rather than inheriting the parent's.
        // Strips DYLD_INSERT_LIBRARIES and other DYLD_* vars that Xcode injects for
        // Swift Previews — helper binaries (shairport-sync, sox, PCMUDPSender) don't
        // have __preview.dylib in their rpath, so dyld terminates them with SIGABRT
        // if those variables are inherited.
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("DYLD_") { env.removeValue(forKey: key) }
        env.merge(environmentOverrides) { _, new in new }
        task.environment = env

        task.terminationHandler = { [weak self] terminated in
            let pid = terminated.processIdentifier
            let status = terminated.terminationStatus
            let reason = terminated.terminationReason
            Task { @MainActor [weak self] in
                guard let self else { return }
                let message = "TaskItem PID=\(pid) - \(self.path) terminationHandler status=\(status) reason=\(reason.rawValue)"
                print(message)
                self.onLog?(message)
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
            let message = "TaskItem - Launched Process PID=\(task.processIdentifier), \(path) \(argsString())"
            print(message)
            onLog?(message)
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
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
        process = nil
        // Wait for graceful exit off the main thread; SIGKILL after 2 seconds if needed.
        Task.detached {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2.0))
            while task.isRunning && ContinuousClock.now < deadline {
                try? await Task.sleep(until: .now.advanced(by: .milliseconds(50)), clock: .continuous)
            }
            if task.isRunning {
                kill(task.processIdentifier, SIGKILL)
            }
        }
    }

    /// Blocking variant of `terminate()`: sends SIGTERM and does not return
    /// until the process has actually exited (SIGKILLing it after `timeout`
    /// if it won't die gracefully). Use this when a caller is about to start
    /// a replacement pipeline immediately and needs any exclusive resource
    /// (hardware device, port) the old process held to be genuinely free —
    /// `terminate()`'s fire-and-forget wait can't provide that guarantee.
    ///
    /// Unlike `terminate()`, this genuinely blocks the calling thread (it
    /// can't dispatch its wait off-thread the way `terminate()` does, or it
    /// would return before the guarantee above holds). If called from
    /// `@MainActor` code — as ControlBooth's `PipelineRunner.start(_:)`
    /// currently does, to free a destination before starting a replacement
    /// pipeline — a subprocess that's slow to exit (stuck hardware I/O, a
    /// wedged device close) can visibly stall the UI for up to
    /// `timeout + 0.5s`. If that ever shows up as a real hitch rather than a
    /// theoretical one, look here first before assuming it's something else.
    public func terminateAndWait(timeout: TimeInterval = 2.0) {
        guard let task = process, task.isRunning else {
            stderrPipe?.fileHandleForReading.readabilityHandler = nil
            stderrPipe = nil
            process = nil
            return
        }
        task.terminate()
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
        process = nil
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if task.isRunning {
            kill(task.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(0.5)
            while task.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    public func taskInfoString() -> String {
        let pid = process?.processIdentifier ?? 0
        let runningFlag = (process?.isRunning ?? false) ? 1 : 0
        return "\(functionName) -  process ID = \(pid) -  isRunning = \(runningFlag)\n\n\"\(path)\" \(argsString())\n\n"
    }
}
