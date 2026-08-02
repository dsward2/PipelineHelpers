import Foundation
import Observation

@MainActor
@Observable
public final class TaskPipelineManager {
    public enum Status {
        case idle
        case running
        case terminating
        case terminated
    }

    public struct Failure {
        public let functionName: String
        public let terminationStatus: Int32
        public let reason: String
    }

    public enum PipelineError: Error, CustomStringConvertible {
        case executableNotFound(String)
        case startFailed(taskFunction: String, underlying: Error)

        public var description: String {
            switch self {
            case .executableNotFound(let name): return "Executable '\(name)' not found in app bundle."
            case .startFailed(let fn, let err): return "Failed to start task '\(fn)': \(err)"
            }
        }
    }

    private static let monitorInterval: Duration = .seconds(5)

    public private(set) var status: Status = .idle
    public private(set) var lastFailure: Failure?
    public private(set) var taskItems: [TaskItem] = []

    /// When the pipeline was most recently started or stopped, for display in the UI.
    public private(set) var lastStartedAt: Date?
    public private(set) var lastStoppedAt: Date?

    private var monitorTask: Task<Void, Never>?

    /// Forwards every task's relayed stderr line (source = that task's
    /// `functionName`) plus this manager's own diagnostic messages, so a
    /// host app can pipe pipeline activity into its own logging system
    /// without this package depending on a concrete log type.
    public var onLog: ((_ source: String, _ message: String) -> Void)?

    public init() {}

    public func makeTaskItem(executableName: String, functionName: String) throws -> TaskItem {
        guard let path = Bundle.main.path(forAuxiliaryExecutable: executableName) else {
            throw PipelineError.executableNotFound(executableName)
        }
        return TaskItem(path: path, functionName: functionName)
    }

    public func makeTaskItem(pathToExecutable: String, functionName: String) -> TaskItem {
        return TaskItem(path: pathToExecutable, functionName: functionName)
    }

    /// Bundled SoX audio tool, embedded in Contents/Helpers alongside the other pipeline helpers.
    public static var soxExecutableURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sox")
    }

    /// Resolves the bundled `sox` executable path, throwing if it is missing from the app bundle.
    public func soxExecutablePath() throws -> String {
        let path = Self.soxExecutableURL.path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw PipelineError.executableNotFound("sox")
        }
        return path
    }

    /// Creates a `TaskItem` for the bundled `sox` tool, ready to receive arguments and be added to the pipeline.
    public func makeSoxTaskItem(functionName: String = "sox") throws -> TaskItem {
        return makeTaskItem(pathToExecutable: try soxExecutablePath(), functionName: functionName)
    }

    public func add(_ taskItem: TaskItem) {
        taskItems.append(taskItem)
    }

    public func start() throws {
        lastFailure = nil
        for item in taskItems {
            item.createTask()
        }
        configureTaskPipes()
        for item in taskItems {
            do {
                try item.start()
            } catch {
                for started in taskItems where started.process?.isRunning == true {
                    started.terminate()
                }
                status = .idle
                throw PipelineError.startFailed(taskFunction: item.functionName, underlying: error)
            }
        }
        status = .running
        lastStartedAt = Date()
        startMonitor()
    }

    public func terminate() {
        monitorTask?.cancel()
        monitorTask = nil
        status = .terminating
        for item in taskItems where item.process?.isRunning == true {
            item.terminate()
        }
        taskItems.removeAll()
        status = .terminated
        lastStoppedAt = Date()
    }

    /// Blocking variant of `terminate()` — does not return until every task's
    /// process has actually exited. See `TaskItem.terminateAndWait`.
    public func terminateAndWait(timeout: TimeInterval = 2.0) {
        monitorTask?.cancel()
        monitorTask = nil
        status = .terminating
        for item in taskItems where item.process?.isRunning == true {
            item.terminateAndWait(timeout: timeout)
        }
        taskItems.removeAll()
        status = .terminated
        lastStoppedAt = Date()
    }

    public func tasksInfoString() -> String {
        guard !taskItems.isEmpty else {
            return "No tasks currently running\n\n"
        }
        return taskItems.map { $0.taskInfoString() }.joined()
    }

    private func configureTaskPipes() {
        guard let first = taskItems.first else { return }
        first.process?.standardInput = FileHandle.nullDevice

        for (idx, item) in taskItems.enumerated() {
            if idx < taskItems.count - 1 {
                let pipe = Pipe()
                item.process?.standardOutput = pipe
                taskItems[idx + 1].process?.standardInput = pipe
            } else {
                item.process?.standardOutput = FileHandle.nullDevice
            }

            let errorPipe = Pipe()
            item.process?.standardError = errorPipe
            item.stderrPipe = errorPipe

            let buffer = StderrLineBuffer()
            let functionName = item.functionName
            errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let lines = buffer.appendAndExtractLines(data)
                guard !lines.isEmpty else { return }
                Task { @MainActor in
                    for line in lines {
                        self?.onLog?(functionName, line)
                    }
                }
            }

            item.onLog = { [weak self] message in
                self?.onLog?(functionName, message)
            }
        }
    }

    private func startMonitor() {
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.monitorInterval)
                if Task.isCancelled { return }
                guard let self else { return }
                self.checkLiveness()
            }
        }
    }

    private func checkLiveness() {
        guard status == .running else { return }
        for item in taskItems {
            let running = item.process?.isRunning ?? false
            if !running {
                let exitStatus: Int32
                if let cached = item.lastTerminationStatus {
                    exitStatus = cached
                } else if let proc = item.process, !proc.isRunning, proc.processIdentifier != 0 {
                    exitStatus = proc.terminationStatus
                } else {
                    exitStatus = -1
                }
                print("TaskPipelineManager - failed task detected - \(item.functionName) exitStatus=\(exitStatus)")
                onLog?(item.functionName, "failed task detected - exitStatus=\(exitStatus)")
                lastFailure = Failure(
                    functionName: item.functionName,
                    terminationStatus: exitStatus,
                    reason: "Task exited unexpectedly"
                )
                terminate()
                return
            }
        }
    }
}

/// Accumulates bytes from a subprocess's stderr `readabilityHandler`
/// (invoked off the main actor on a GCD-managed queue) and extracts complete
/// newline-terminated lines. A locked reference type rather than a captured
/// `var` so the closure stays free of the "mutation of captured var in
/// concurrently-executing code" Sendable warning that would otherwise be an
/// error under Swift 6 strict concurrency.
private final class StderrLineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func appendAndExtractLines(_ newData: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        data.append(newData)
        var lines: [String] = []
        while let newlineIndex = data.firstIndex(of: 0x0A) {
            let lineData = data[data.startIndex..<newlineIndex]
            data.removeSubrange(data.startIndex...newlineIndex)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }
}
