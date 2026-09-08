import Darwin
import Foundation

public enum EngineLifecycleState: Equatable, Sendable {
  case stopped
  case starting
  case loading
  case ready
  case stopping
  case failed(String)
}

public enum EngineEvent: Equatable, Sendable {
  case stateChanged(EngineLifecycleState)
  case log(String)
  case exited(status: Int32)
}

public enum EngineSupervisorError: Error, LocalizedError {
  case alreadyRunning
  case executableMissing(String)
  case executableNotRunnable(String)
  case exitedBeforeReady(status: Int32)
  case healthCheckTimedOut

  public var errorDescription: String? {
    switch self {
    case .alreadyRunning:
      "An engine process is already running."
    case .executableMissing(let path):
      "The engine executable does not exist: \(path)"
    case .executableNotRunnable(let path):
      "The engine executable is not runnable: \(path)"
    case .exitedBeforeReady(let status):
      "The engine exited before becoming ready with status \(status)."
    case .healthCheckTimedOut:
      "The engine did not become healthy before the startup timeout."
    }
  }
}

public struct EngineLaunchConfiguration: Sendable {
  public var executableURL: URL
  public var arguments: [String]
  public var environment: [String: String]
  public var workingDirectory: URL?
  public var healthURL: URL
  public var startupTimeout: Duration

  public init(
    executableURL: URL,
    arguments: [String],
    environment: [String: String] = [:],
    workingDirectory: URL? = nil,
    healthURL: URL,
    startupTimeout: Duration = .seconds(180)
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.environment = environment
    self.workingDirectory = workingDirectory
    self.healthURL = healthURL
    self.startupTimeout = startupTimeout
  }
}

public actor EngineSupervisor {
  public nonisolated let events: AsyncStream<EngineEvent>

  private let eventContinuation: AsyncStream<EngineEvent>.Continuation
  private let urlSession: URLSession
  private var process: Process?
  private var outputPipe: Pipe?
  private var lifecycleState = EngineLifecycleState.stopped
  private var stoppingRequested = false

  public init(urlSession: URLSession = .shared) {
    let pair = AsyncStream<EngineEvent>.makeStream()
    events = pair.stream
    eventContinuation = pair.continuation
    self.urlSession = urlSession
  }

  public var state: EngineLifecycleState {
    lifecycleState
  }

  public var processIdentifier: Int32? {
    process?.processIdentifier
  }

  public func start(_ configuration: EngineLaunchConfiguration) async throws {
    guard process == nil else {
      throw EngineSupervisorError.alreadyRunning
    }

    let path = configuration.executableURL.path
    guard FileManager.default.fileExists(atPath: path) else {
      throw EngineSupervisorError.executableMissing(path)
    }
    guard FileManager.default.isExecutableFile(atPath: path) else {
      throw EngineSupervisorError.executableNotRunnable(path)
    }

    transition(to: .starting)
    stoppingRequested = false

    let process = Process()
    let outputPipe = Pipe()
    process.executableURL = configuration.executableURL
    process.arguments = configuration.arguments
    process.currentDirectoryURL = configuration.workingDirectory
    process.environment = ProcessInfo.processInfo.environment.merging(
      configuration.environment,
      uniquingKeysWith: { _, configured in configured }
    )
    process.standardOutput = outputPipe
    process.standardError = outputPipe
    process.terminationHandler = { [weak self] terminatedProcess in
      Task {
        await self?.handleTermination(
          processID: terminatedProcess.processIdentifier,
          status: terminatedProcess.terminationStatus
        )
      }
    }
    outputPipe.fileHandleForReading.readabilityHandler = {
      [continuation = eventContinuation] handle in
      let data = handle.availableData
      guard !data.isEmpty, let text = String(data: data, encoding: .utf8)
      else {
        return
      }
      continuation.yield(.log(text))
    }

    do {
      try process.run()
    } catch {
      outputPipe.fileHandleForReading.readabilityHandler = nil
      transition(to: .failed(error.localizedDescription))
      throw error
    }

    self.process = process
    self.outputPipe = outputPipe
    transition(to: .loading)

    do {
      try await waitUntilHealthy(
        url: configuration.healthURL,
        timeout: configuration.startupTimeout
      )
      transition(to: .ready)
    } catch {
      await stop()
      throw error
    }
  }

  public func stop(gracePeriod: Duration = .seconds(3)) async {
    guard let process else {
      transition(to: .stopped)
      return
    }

    stoppingRequested = true
    transition(to: .stopping)
    if process.isRunning {
      process.terminate()
    }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: gracePeriod)
    while process.isRunning, clock.now < deadline {
      try? await Task.sleep(for: .milliseconds(50))
    }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
    }
    cleanupProcess()
    transition(to: .stopped)
  }

  private func waitUntilHealthy(url: URL, timeout: Duration) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while clock.now < deadline {
      if let process, !process.isRunning {
        throw EngineSupervisorError.exitedBeforeReady(
          status: process.terminationStatus
        )
      }

      do {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        let (_, response) = try await urlSession.data(for: request)
        if let response = response as? HTTPURLResponse,
          (200..<300).contains(response.statusCode)
        {
          return
        }
      } catch {
        // Loading and connection-refused responses are expected here.
      }
      try await Task.sleep(for: .milliseconds(200))
    }
    throw EngineSupervisorError.healthCheckTimedOut
  }

  private func handleTermination(processID: Int32, status: Int32) {
    guard process?.processIdentifier == processID else {
      return
    }
    eventContinuation.yield(.exited(status: status))
    cleanupProcess()
    if stoppingRequested {
      transition(to: .stopped)
    } else {
      transition(
        to: .failed("Engine exited unexpectedly with status \(status).")
      )
    }
  }

  private func cleanupProcess() {
    outputPipe?.fileHandleForReading.readabilityHandler = nil
    outputPipe = nil
    process = nil
  }

  private func transition(to newState: EngineLifecycleState) {
    guard lifecycleState != newState else {
      return
    }
    lifecycleState = newState
    eventContinuation.yield(.stateChanged(newState))
  }
}
