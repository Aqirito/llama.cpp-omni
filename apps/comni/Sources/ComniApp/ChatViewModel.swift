import ComniDomain
import ComniMedia
import ComniRuntime
import Foundation
import Observation

@MainActor
@Observable
final class ChatViewModel {
  var messages: [ChatMessage] = []
  var composer = ""
  var isGenerating = false
  var ttsEnabled = false
  var thinkingEnabled = false
  var runtimeStatus = "Runtime not connected"
  var errorMessage: String?
  var hasReferenceVoice = false

  private let audioPlayback = AudioPlaybackService()
  private let runtimeLog = RuntimeLogStore.shared
  private var engineSupervisor: EngineSupervisor?
  private var backendClient: OmniBackendClient?
  private var engineEventTask: Task<Void, Never>?
  private var backendEventTask: Task<Void, Never>?
  private var installation: ModelInstallation?
  private var sessionReady = false
  private var pendingAssistantID: UUID?

  func send() async {
    let text = composer.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !isGenerating else {
      return
    }

    composer = ""
    errorMessage = nil
    let userMessage = ChatMessage(role: .user, text: text)
    messages.append(userMessage)
    let requestMessages = messages

    let assistant = ChatMessage(role: .assistant, text: "")
    pendingAssistantID = assistant.id
    messages.append(assistant)
    isGenerating = true

    do {
      try await ensureSession()
      try await backendClient?.appendChat(
        ChatRequest(
          messages: requestMessages,
          streaming: true,
          ttsEnabled: ttsEnabled,
          enableThinking: thinkingEnabled
        )
      )
    } catch {
      await failTurn(error)
    }
  }

  func stop() async {
    isGenerating = false
    pendingAssistantID = nil
    try? await backendClient?.close(reason: "user_ended")
    backendClient = nil
    backendEventTask?.cancel()
    backendEventTask = nil
    await engineSupervisor?.stop()
    engineSupervisor = nil
    installation = nil
    engineEventTask?.cancel()
    engineEventTask = nil
    audioPlayback.stop()
    sessionReady = false
    runtimeStatus = "Runtime stopped"
  }

  private func ensureSession() async throws {
    if sessionReady {
      return
    }
    if backendClient == nil {
      try await startSession()
    }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(180))
    while !sessionReady, clock.now < deadline {
      if let errorMessage {
        throw ChatSetupError.runtimeFailed(errorMessage)
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    guard sessionReady else {
      throw ChatSetupError.sessionTimedOut
    }
  }

  private func startSession() async throws {
    let port = 11_435
    let baseURL = URL(string: "http://127.0.0.1:\(port)")!
    if engineSupervisor == nil {
      let environment = ProcessInfo.processInfo.environment
      guard
        let modelPath = environment["COMNI_MODEL_DIR"],
        let serverPath = environment["COMNI_SERVER_PATH"]
      else {
        throw ChatSetupError.missingDevelopmentConfiguration
      }

      let modelRoot = URL(fileURLWithPath: modelPath, isDirectory: true)
      let installations = try MiniCPMOModelDiscovery().discover(in: modelRoot)
      guard
        let selectedInstallation =
          installations.first(where: {
            $0.bundle.variant == "Q4_K_M" && $0.supportsVisionLive
          })
          ?? installations.first(where: \.supportsVisionLive),
        let llmURL = selectedInstallation.url(for: .llm)
      else {
        throw ChatSetupError.noRunnableModel(modelRoot.path)
      }
      installation = selectedInstallation

      let supervisor = EngineSupervisor()
      engineSupervisor = supervisor
      observeEngine(supervisor)
      runtimeStatus = "Starting runtime"
      try await supervisor.start(
        EngineLaunchConfiguration(
          executableURL: URL(fileURLWithPath: serverPath),
          arguments: [
            "-m", llmURL.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "-c", "8192",
            "--no-ui",
          ],
          workingDirectory: URL(fileURLWithPath: serverPath)
            .deletingLastPathComponent(),
          healthURL: baseURL.appendingPathComponent("health")
        )
      )
    }

    guard let installation else {
      throw ChatSetupError.runtimeFailed("Model installation was not retained.")
    }

    let client = OmniBackendClient(baseURL: baseURL)
    backendClient = client
    let events = try await client.connect(
      configuration: LiveSessionConfiguration(
        modelID: installation.id,
        mode: .chat,
        generateAudio: ttsEnabled && installation.supportsSpeechOutput
      )
    )
    observeBackend(events)
  }

  private func observeEngine(_ supervisor: EngineSupervisor) {
    engineEventTask = Task { [weak self] in
      for await event in supervisor.events {
        guard let self else { return }
        switch event {
        case .stateChanged(.ready):
          runtimeStatus = "Runtime ready"
        case .stateChanged(.loading):
          runtimeStatus = "Runtime loading"
        case .stateChanged(.starting):
          runtimeStatus = "Runtime starting"
        case .stateChanged(.stopping):
          runtimeStatus = "Runtime stopping"
        case .stateChanged(.stopped):
          runtimeStatus = "Runtime stopped"
        case .stateChanged(.failed(let message)):
          runtimeStatus = "Runtime failed"
          errorMessage = message
        case .exited(let status):
          if status != 0 {
            runtimeStatus = "Runtime exited (\(status))"
          }
        case .log(let message):
          await runtimeLog.append(source: "engine", message: message)
        }
      }
    }
  }

  private func observeBackend(
    _ events: AsyncThrowingStream<LiveSessionEvent, Error>
  ) {
    backendEventTask = Task { [weak self] in
      do {
        for try await event in events {
          guard let self else { return }
          await handle(event)
        }
      } catch {
        guard let self else { return }
        await failTurn(error)
      }
    }
  }

  private func handle(_ event: LiveSessionEvent) async {
    switch event {
    case .sessionCreated:
      sessionReady = true
      runtimeStatus = "Chat ready"
    case .stateChanged(.failed):
      await failTurn(ChatSetupError.runtimeFailed("Backend session failed."))
    case .stateChanged:
      break
    case .textDelta(let text):
      appendAssistantText(text)
    case .audioDelta(let data):
      try? audioPlayback.enqueue(data, sampleRate: 24_000)
    case .responseCompleted(let text, let audio, _):
      if assistantText.isEmpty, !text.isEmpty {
        appendAssistantText(text)
      }
      if let audio {
        try? audioPlayback.enqueue(audio, sampleRate: 24_000)
      }
      await finishTurnSession()
      pendingAssistantID = nil
      isGenerating = false
    case .metrics(let metrics):
      if let kv = metrics.kvCacheLength {
        runtimeStatus = "Chat ready - KV \(kv)"
      }
    case .ended(let reason):
      sessionReady = false
      runtimeStatus =
        engineSupervisor == nil ? "Session ended: \(reason)" : "Runtime ready"
    }
  }

  private func finishTurnSession() async {
    try? await backendClient?.close(reason: "turn_complete")
    backendClient = nil
    sessionReady = false
  }

  private var assistantText: String {
    guard
      let pendingAssistantID,
      let message = messages.first(where: { $0.id == pendingAssistantID })
    else {
      return ""
    }
    return message.text
  }

  private func appendAssistantText(_ text: String) {
    guard
      let pendingAssistantID,
      let index = messages.firstIndex(where: { $0.id == pendingAssistantID })
    else {
      return
    }
    let current = messages[index].text
    messages[index].content = [.text(current + text)]
  }

  private func failTurn(_ error: Error) async {
    await runtimeLog.append(
      source: "chat",
      message: "turn failed: \(error.localizedDescription)"
    )
    await backendClient?.cancel()
    backendClient = nil
    sessionReady = false
    isGenerating = false
    errorMessage = error.localizedDescription
    if let pendingAssistantID,
      let index = messages.firstIndex(where: { $0.id == pendingAssistantID }),
      messages[index].text.isEmpty
    {
      messages.remove(at: index)
    }
    pendingAssistantID = nil
  }
}

private enum ChatSetupError: Error, LocalizedError {
  case missingDevelopmentConfiguration
  case noRunnableModel(String)
  case sessionTimedOut
  case runtimeFailed(String)

  var errorDescription: String? {
    switch self {
    case .missingDevelopmentConfiguration:
      "Set COMNI_MODEL_DIR and COMNI_SERVER_PATH before sending a message."
    case .noRunnableModel(let path):
      "No runnable MiniCPM-o model bundle was found at \(path)."
    case .sessionTimedOut:
      "The Chat session did not become ready in time."
    case .runtimeFailed(let message):
      message
    }
  }
}
