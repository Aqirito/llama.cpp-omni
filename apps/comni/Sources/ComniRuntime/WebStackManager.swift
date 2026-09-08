import Foundation

public enum WebStackComponent: String, Sendable {
  case frontend
  case backend
  case worker
  case gateway
}

public enum WebStackState: Equatable, Sendable {
  case stopped
  case starting(WebStackComponent)
  case running
  case stopping
  case failed(String)
}

public enum WebStackEvent: Equatable, Sendable {
  case stateChanged(WebStackState)
  case componentState(WebStackComponent, EngineLifecycleState)
}

public enum WebStackError: Error, LocalizedError {
  case alreadyRunning
  case registrationFailed(statusCode: Int)
  case invalidStatus
  case frontendBuildFailed(command: String, status: Int32)
  case frontendOutputMissing
  case portUnavailable(Int)

  public var errorDescription: String? {
    switch self {
    case .alreadyRunning:
      "The Comni Web stack is already running."
    case .registrationFailed(let statusCode):
      "The Gateway rejected worker registration with HTTP \(statusCode)."
    case .invalidStatus:
      "The Gateway did not report a healthy idle worker."
    case .frontendBuildFailed(let command, let status):
      "The mobile frontend command '\(command)' failed with status \(status)."
    case .frontendOutputMissing:
      "The mobile frontend build completed without static/mobile/index.html."
    case .portUnavailable(let port):
      "The loopback port \(port) is already in use."
    }
  }
}

public struct WebStackConfiguration: Sendable {
  public var serverURL: URL
  public var pythonURL: URL
  public var demoRootURL: URL
  public var modelURL: URL
  public var backendPort: Int
  public var workerPort: Int
  public var gatewayPort: Int
  public var internalGatewayPort: Int
  public var contextSize: Int
  public var gpuLayers: Int

  public init(
    serverURL: URL,
    pythonURL: URL,
    demoRootURL: URL,
    modelURL: URL,
    backendPort: Int = 22_620,
    workerPort: Int = 22_621,
    gatewayPort: Int = 18_006,
    internalGatewayPort: Int = 18_007,
    contextSize: Int = 8192,
    gpuLayers: Int = 99
  ) {
    self.serverURL = serverURL
    self.pythonURL = pythonURL
    self.demoRootURL = demoRootURL
    self.modelURL = modelURL
    self.backendPort = backendPort
    self.workerPort = workerPort
    self.gatewayPort = gatewayPort
    self.internalGatewayPort = internalGatewayPort
    self.contextSize = contextSize
    self.gpuLayers = gpuLayers
  }

  public var webURL: URL {
    URL(string: "http://127.0.0.1:\(gatewayPort)/mobile/")!
  }
}

public actor WebStackManager {
  public nonisolated let events: AsyncStream<WebStackEvent>

  private let eventContinuation: AsyncStream<WebStackEvent>.Continuation
  private let urlSession: URLSession
  private let logStore: RuntimeLogStore
  private var backend: EngineSupervisor?
  private var worker: EngineSupervisor?
  private var gateway: EngineSupervisor?
  private var eventTasks: [Task<Void, Never>] = []
  private var currentState = WebStackState.stopped

  public init(
    urlSession: URLSession = .shared,
    logStore: RuntimeLogStore = .shared
  ) {
    let pair = AsyncStream<WebStackEvent>.makeStream()
    events = pair.stream
    eventContinuation = pair.continuation
    self.urlSession = urlSession
    self.logStore = logStore
  }

  public var state: WebStackState {
    currentState
  }

  public func start(_ configuration: WebStackConfiguration) async throws {
    guard currentState == .stopped else {
      throw WebStackError.alreadyRunning
    }

    do {
      let allocator = LoopbackPortAllocator()
      for port in [
        configuration.backendPort,
        configuration.workerPort,
        configuration.gatewayPort,
        configuration.internalGatewayPort,
      ] {
        guard allocator.isAvailable(port) else {
          throw WebStackError.portUnavailable(port)
        }
      }

      transition(to: .starting(.frontend))
      try await prepareMobileFrontend(configuration)

      let backend = EngineSupervisor(urlSession: urlSession)
      self.backend = backend
      observe(backend, component: .backend)
      transition(to: .starting(.backend))
      try await backend.start(
        EngineLaunchConfiguration(
          executableURL: configuration.serverURL,
          arguments: [
            "-m", configuration.modelURL.path,
            "-ngl", String(configuration.gpuLayers),
            "-c", String(configuration.contextSize),
            "--host", "127.0.0.1",
            "--port", String(configuration.backendPort),
            "--no-ui",
          ],
          workingDirectory: configuration.serverURL.deletingLastPathComponent(),
          healthURL: componentURL(port: configuration.backendPort, path: "health")
        )
      )

      let worker = EngineSupervisor(urlSession: urlSession)
      self.worker = worker
      observe(worker, component: .worker)
      transition(to: .starting(.worker))
      try await worker.start(
        EngineLaunchConfiguration(
          executableURL: configuration.pythonURL,
          arguments: [
            "worker.py",
            "--host", "127.0.0.1",
            "--port", String(configuration.workerPort),
            "--gpu-id", "0",
            "--backend-server-url",
            "http://127.0.0.1:\(configuration.backendPort)",
          ],
          environment: ["PYTHONPATH": "."],
          workingDirectory: configuration.demoRootURL,
          healthURL: componentURL(port: configuration.workerPort, path: "health")
        )
      )

      let gateway = EngineSupervisor(urlSession: urlSession)
      self.gateway = gateway
      observe(gateway, component: .gateway)
      transition(to: .starting(.gateway))
      try await gateway.start(
        EngineLaunchConfiguration(
          executableURL: configuration.pythonURL,
          arguments: [
            "gateway.py",
            "--host", "127.0.0.1",
            "--port", String(configuration.gatewayPort),
            "--internal-port", String(configuration.internalGatewayPort),
            "--http",
          ],
          environment: ["PYTHONPATH": "."],
          workingDirectory: configuration.demoRootURL,
          healthURL: componentURL(port: configuration.gatewayPort, path: "health")
        )
      )

      try await registerWorker(configuration)
      try await verifyStatus(configuration)
      transition(to: .running)
    } catch {
      await stop()
      transition(to: .failed(error.localizedDescription))
      throw error
    }
  }

  public func stop() async {
    if currentState != .stopped {
      transition(to: .stopping)
    }
    await gateway?.stop()
    gateway = nil
    await worker?.stop()
    worker = nil
    await backend?.stop()
    backend = nil
    for task in eventTasks {
      task.cancel()
    }
    eventTasks.removeAll()
    transition(to: .stopped)
  }

  private func prepareMobileFrontend(
    _ configuration: WebStackConfiguration
  ) async throws {
    let indexURL =
      configuration.demoRootURL
      .appendingPathComponent("static/mobile/index.html")
    if FileManager.default.fileExists(atPath: indexURL.path) {
      eventContinuation.yield(.componentState(.frontend, .ready))
      return
    }

    let frontendURL =
      configuration.demoRootURL
      .appendingPathComponent("frontend/mobile", isDirectory: true)
    let nodeModulesURL = frontendURL.appendingPathComponent(
      "node_modules",
      isDirectory: true
    )

    eventContinuation.yield(.componentState(.frontend, .loading))
    if !FileManager.default.fileExists(atPath: nodeModulesURL.path) {
      try await runFrontendCommand(
        ["npm", "install", "--no-package-lock"],
        workingDirectory: frontendURL
      )
    }
    try await runFrontendCommand(
      ["npm", "run", "build:static"],
      workingDirectory: frontendURL
    )

    guard FileManager.default.fileExists(atPath: indexURL.path) else {
      throw WebStackError.frontendOutputMissing
    }
    eventContinuation.yield(.componentState(.frontend, .ready))
  }

  private func runFrontendCommand(
    _ arguments: [String],
    workingDirectory: URL
  ) async throws {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.currentDirectoryURL = workingDirectory
    process.environment = ProcessInfo.processInfo.environment
    process.standardOutput = pipe
    process.standardError = pipe

    let command = arguments.joined(separator: " ")
    let logStore = self.logStore
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard
        !data.isEmpty,
        let text = String(data: data, encoding: .utf8)
      else {
        return
      }
      Task {
        await logStore.append(source: "frontend", message: text)
      }
    }

    let status: Int32 = try await withCheckedThrowingContinuation {
      continuation in
      process.terminationHandler = { process in
        continuation.resume(returning: process.terminationStatus)
      }
      do {
        try process.run()
      } catch {
        continuation.resume(throwing: error)
      }
    }
    pipe.fileHandleForReading.readabilityHandler = nil
    guard status == 0 else {
      throw WebStackError.frontendBuildFailed(
        command: command,
        status: status
      )
    }
  }

  private func registerWorker(_ configuration: WebStackConfiguration) async throws {
    let url = URL(
      string:
        "http://127.0.0.1:\(configuration.internalGatewayPort)/internal/workers/comni-local"
    )!
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.httpBody = try JSONSerialization.data(
      withJSONObject: [
        "endpoint": "127.0.0.1:\(configuration.workerPort)",
        "gpu_group": "apple-silicon",
      ]
    )
    let (_, response) = try await urlSession.data(for: request)
    guard
      let response = response as? HTTPURLResponse,
      (200..<300).contains(response.statusCode)
    else {
      throw WebStackError.registrationFailed(
        statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1
      )
    }
  }

  private func verifyStatus(_ configuration: WebStackConfiguration) async throws {
    let url = componentURL(port: configuration.gatewayPort, path: "status")
    let (data, response) = try await urlSession.data(from: url)
    guard
      let response = response as? HTTPURLResponse,
      (200..<300).contains(response.statusCode),
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["gateway_healthy"] as? Bool == true,
      (object["idle_workers"] as? Int ?? 0) >= 1
    else {
      throw WebStackError.invalidStatus
    }
  }

  private func observe(
    _ supervisor: EngineSupervisor,
    component: WebStackComponent
  ) {
    let task = Task { [logStore, eventContinuation] in
      for await event in supervisor.events {
        switch event {
        case .stateChanged(let state):
          eventContinuation.yield(.componentState(component, state))
        case .log(let message):
          await logStore.append(source: component.rawValue, message: message)
        case .exited(let status):
          await logStore.append(
            source: component.rawValue,
            message: "process exited with status \(status)"
          )
        }
      }
    }
    eventTasks.append(task)
  }

  private func componentURL(port: Int, path: String) -> URL {
    URL(string: "http://127.0.0.1:\(port)/\(path)")!
  }

  private func transition(to state: WebStackState) {
    guard currentState != state else {
      return
    }
    currentState = state
    eventContinuation.yield(.stateChanged(state))
  }
}
