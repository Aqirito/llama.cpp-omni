import AppKit
import ComniRuntime
import Foundation
import Observation

@MainActor
@Observable
final class WebManagerViewModel {
  var modelDirectory: String
  var demoDirectory: String
  var serverPath: String
  var pythonPath: String
  var stackState = WebStackState.stopped
  var componentStates: [WebStackComponent: EngineLifecycleState] = [:]
  var errorMessage: String?
  var webURL: URL?

  private let manager = WebStackManager()
  private var eventTask: Task<Void, Never>?

  init() {
    let environment = ProcessInfo.processInfo.environment
    let defaults = UserDefaults.standard
    let legacyModelDirectory =
      FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(
        ".comni/models/MiniCPM-o-4_5-gguf",
        isDirectory: true
      ).path
    let configuredModelDirectory =
      defaults.string(forKey: "comni.web.modelDirectory")
      ?? environment["COMNI_MODEL_DIR"] ?? ""
    if FileManager.default.fileExists(atPath: legacyModelDirectory),
      configuredModelDirectory.isEmpty
        || configuredModelDirectory.hasPrefix("/tmp/comni-")
    {
      modelDirectory = legacyModelDirectory
    } else {
      modelDirectory = configuredModelDirectory
    }
    demoDirectory =
      defaults.string(forKey: "comni.web.demoDirectory")
      ?? environment["COMNI_DEMO_DIR"] ?? ""
    serverPath =
      defaults.string(forKey: "comni.web.serverPath")
      ?? environment["COMNI_SERVER_PATH"] ?? ""
    pythonPath =
      defaults.string(forKey: "comni.web.pythonPath")
      ?? environment["COMNI_PYTHON_PATH"] ?? ""
  }

  var isRunning: Bool {
    stackState == .running
  }

  var isConfigured: Bool {
    !modelDirectory.isEmpty
      && !demoDirectory.isEmpty
      && !serverPath.isEmpty
      && !pythonPath.isEmpty
  }

  var isBusy: Bool {
    switch stackState {
    case .starting, .stopping:
      true
    default:
      false
    }
  }

  var summary: String {
    switch stackState {
    case .stopped:
      "Services are stopped"
    case .starting(let component):
      "Starting \(component.rawValue)"
    case .running:
      "Web app is ready"
    case .stopping:
      "Stopping services"
    case .failed(let message):
      "Failed: \(message)"
    }
  }

  func start() async {
    guard !isBusy, !isRunning else {
      return
    }
    errorMessage = nil
    do {
      let configuration = try makeConfiguration()
      persistPaths()
      observeEvents()
      try await manager.start(configuration)
      webURL = configuration.webURL
      NSWorkspace.shared.open(configuration.webURL)
    } catch {
      await manager.stop()
      stackState = .failed(error.localizedDescription)
      errorMessage = error.localizedDescription
    }
  }

  func stop() async {
    guard stackState != .stopped else {
      return
    }
    await manager.stop()
    componentStates.removeAll()
    webURL = nil
  }

  func openWeb() {
    guard let webURL else {
      return
    }
    NSWorkspace.shared.open(webURL)
  }

  func showLogs() async {
    let url = await RuntimeLogStore.shared.fileURL
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  func chooseModelDirectory() {
    if let url = choosePath(directoriesOnly: true) {
      modelDirectory = url.path
    }
  }

  func chooseDemoDirectory() {
    if let url = choosePath(directoriesOnly: true) {
      demoDirectory = url.path
    }
  }

  func chooseServer() {
    if let url = choosePath(directoriesOnly: false) {
      serverPath = url.path
    }
  }

  func choosePython() {
    if let url = choosePath(directoriesOnly: false) {
      pythonPath = url.path
    }
  }

  private func makeConfiguration() throws -> WebStackConfiguration {
    let modelRoot = try requiredDirectory(modelDirectory, label: "Model directory")
    let demoRoot = try requiredDirectory(demoDirectory, label: "Demo directory")
    let serverURL = try requiredExecutable(serverPath, label: "llama-omni-server")
    let pythonURL = try requiredExecutable(pythonPath, label: "Python")

    guard
      FileManager.default.fileExists(
        atPath: demoRoot.appendingPathComponent("gateway.py").path
      ),
      FileManager.default.fileExists(
        atPath: demoRoot.appendingPathComponent("worker.py").path
      )
    else {
      throw WebManagerError.invalidDemoDirectory
    }

    let installations = try MiniCPMOModelDiscovery().discover(in: modelRoot)
    guard
      let installation =
        installations.first(where: {
          $0.bundle.variant == "Q4_K_M" && $0.supportsVisionLive
        })
        ?? installations.first(where: \.supportsVisionLive),
      let modelURL = installation.url(for: .llm)
    else {
      throw WebManagerError.noRunnableModel
    }

    let ports = try LoopbackPortAllocator().allocate(count: 4)
    return WebStackConfiguration(
      serverURL: serverURL,
      pythonURL: pythonURL,
      demoRootURL: demoRoot,
      modelURL: modelURL,
      backendPort: ports[0],
      workerPort: ports[1],
      gatewayPort: ports[2],
      internalGatewayPort: ports[3]
    )
  }

  private func observeEvents() {
    eventTask?.cancel()
    eventTask = Task { [weak self] in
      guard let self else {
        return
      }
      for await event in manager.events {
        switch event {
        case .stateChanged(let state):
          stackState = state
        case .componentState(let component, let state):
          componentStates[component] = state
        }
      }
    }
  }

  private func persistPaths() {
    let defaults = UserDefaults.standard
    defaults.set(modelDirectory, forKey: "comni.web.modelDirectory")
    defaults.set(demoDirectory, forKey: "comni.web.demoDirectory")
    defaults.set(serverPath, forKey: "comni.web.serverPath")
    defaults.set(pythonPath, forKey: "comni.web.pythonPath")
  }

  private func requiredDirectory(_ path: String, label: String) throws -> URL {
    var isDirectory: ObjCBool = false
    guard
      !path.isEmpty,
      FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw WebManagerError.missingPath(label)
    }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  private func requiredExecutable(_ path: String, label: String) throws -> URL {
    guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
      throw WebManagerError.missingPath(label)
    }
    return URL(fileURLWithPath: path)
  }

  private func choosePath(directoriesOnly: Bool) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = directoriesOnly
    panel.canChooseFiles = !directoriesOnly
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    return panel.runModal() == .OK ? panel.url : nil
  }
}

private enum WebManagerError: Error, LocalizedError {
  case missingPath(String)
  case invalidDemoDirectory
  case noRunnableModel

  var errorDescription: String? {
    switch self {
    case .missingPath(let label):
      "\(label) is missing or invalid."
    case .invalidDemoDirectory:
      "The selected Demo directory does not contain gateway.py and worker.py."
    case .noRunnableModel:
      "No complete MiniCPM-o model bundle was found."
    }
  }
}
