import ComniDomain
import ComniMedia
import ComniRuntime
import Foundation
import Observation

@MainActor
@Observable
final class LiveViewModel {
  var sessionState = LiveSessionState.idle
  var transcriptVisible = true
  var microphoneEnabled = true
  var cameraEnabled = true
  var cameraMirrored = true
  var errorMessage: String?
  var runtimeStatus = "Runtime not connected"
  var transcript = ""

  let cameraCapture = CameraCaptureService()

  private let authorization = MediaAuthorization()
  private let audioCapture = AudioCaptureService()
  private let audioPlayback = AudioPlaybackService()
  private let inputAssembler = LiveInputAssembler()
  private let runtimeLog = RuntimeLogStore.shared
  private var engineSupervisor: EngineSupervisor?
  private var backendClient: OmniBackendClient?
  private var engineEventTask: Task<Void, Never>?
  private var backendEventTask: Task<Void, Never>?
  private var cameraFrameTask: Task<Void, Never>?
  private var audioChunkTask: Task<Void, Never>?

  func startLive() async {
    guard sessionState == .idle || sessionState == .ended || sessionState == .failed
    else {
      return
    }

    sessionState = .preparing
    errorMessage = nil
    transcript = ""
    do {
      let environment = ProcessInfo.processInfo.environment
      guard
        let modelPath = environment["COMNI_MODEL_DIR"],
        let serverPath = environment["COMNI_SERVER_PATH"]
      else {
        throw LiveSetupError.missingDevelopmentConfiguration
      }

      let modelRoot = URL(fileURLWithPath: modelPath, isDirectory: true)
      let installation = try selectInstallation(at: modelRoot)
      let port = 11_435
      let baseURL = URL(string: "http://127.0.0.1:\(port)")!

      let supervisor = EngineSupervisor()
      engineSupervisor = supervisor
      observeEngine(supervisor)
      runtimeStatus = "Starting runtime"
      try await supervisor.start(
        EngineLaunchConfiguration(
          executableURL: URL(fileURLWithPath: serverPath),
          arguments: [
            "-m", installation.url(for: .llm)!.path,
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

      let client = OmniBackendClient(baseURL: baseURL)
      backendClient = client
      let events = try await client.connect(
        configuration: LiveSessionConfiguration(
          modelID: installation.id,
          mode: .visionLive,
          generateAudio: installation.supportsSpeechOutput
        )
      )
      observeBackend(events)
    } catch {
      await fail(error)
    }
  }

  func stop() async {
    guard sessionState != .idle && sessionState != .ended else {
      return
    }
    sessionState = .ending
    stopMediaTasks()
    await stopMedia()
    try? await backendClient?.close(reason: "user_ended")
    backendClient = nil
    backendEventTask?.cancel()
    backendEventTask = nil
    await engineSupervisor?.stop()
    engineSupervisor = nil
    engineEventTask?.cancel()
    engineEventTask = nil
    await inputAssembler.reset()
    runtimeStatus = "Runtime stopped"
    sessionState = .ended
  }

  func toggleMicrophone() async {
    microphoneEnabled.toggle()
    do {
      if microphoneEnabled {
        try await authorizeMicrophone()
        try audioCapture.start()
      } else {
        audioCapture.stop()
      }
    } catch {
      microphoneEnabled = false
      errorMessage = error.localizedDescription
    }
  }

  func toggleCamera() async {
    cameraEnabled.toggle()
    do {
      if cameraEnabled {
        try await authorizeCamera()
        try await cameraCapture.start()
      } else {
        await cameraCapture.stop()
      }
    } catch {
      cameraEnabled = false
      errorMessage = error.localizedDescription
    }
  }

  func switchCamera() async {
    do {
      try await cameraCapture.switchCamera()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func selectInstallation(at rootURL: URL) throws -> ModelInstallation {
    let installations = try MiniCPMOModelDiscovery().discover(in: rootURL)
    guard
      let installation =
        installations.first(where: {
          $0.bundle.variant == "Q4_K_M" && $0.supportsVisionLive
        })
        ?? installations.first(where: \.supportsVisionLive)
    else {
      throw LiveSetupError.noRunnableModel(rootURL.path)
    }
    return installation
  }

  private func observeEngine(_ supervisor: EngineSupervisor) {
    engineEventTask?.cancel()
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
          if sessionState != .ending && sessionState != .ended {
            errorMessage = message
            sessionState = .failed
          }
        case .log(let message):
          await runtimeLog.append(source: "engine", message: message)
        case .exited(let status):
          if status != 0 && sessionState != .ending && sessionState != .ended {
            runtimeStatus = "Runtime exited (\(status))"
          }
        }
      }
    }
  }

  private func observeBackend(
    _ events: AsyncThrowingStream<LiveSessionEvent, Error>
  ) {
    backendEventTask?.cancel()
    backendEventTask = Task { [weak self] in
      do {
        for try await event in events {
          guard let self else { return }
          try await handle(event)
        }
      } catch {
        guard let self, sessionState != .ending, sessionState != .ended else {
          return
        }
        await fail(error)
      }
    }
  }

  private func handle(_ event: LiveSessionEvent) async throws {
    switch event {
    case .sessionCreated:
      runtimeStatus = "Model ready"
    case .stateChanged(.ready):
      try await startMedia()
      sessionState = .listening
    case .stateChanged(let state):
      sessionState = state
    case .textDelta(let text):
      transcript += text
    case .audioDelta(let data):
      try audioPlayback.enqueue(data, sampleRate: 24_000)
    case .responseCompleted(let text, let audio, _):
      if !text.isEmpty {
        transcript = text
      }
      if let audio {
        try audioPlayback.enqueue(audio, sampleRate: 24_000)
      }
    case .metrics(let metrics):
      if let kv = metrics.kvCacheLength {
        runtimeStatus = "Live - KV \(kv)"
      }
    case .ended:
      stopMediaTasks()
      await stopMedia()
      runtimeStatus = "Session ended"
      sessionState = .ended
    }
  }

  private func startMedia() async throws {
    if cameraEnabled {
      try await authorizeCamera()
      try await cameraCapture.start()
    }
    if microphoneEnabled {
      try await authorizeMicrophone()
      try audioCapture.start()
    }
    try audioPlayback.start(sampleRate: 24_000)

    cameraFrameTask = Task { [weak self] in
      guard let self else { return }
      for await frame in cameraCapture.frames {
        if Task.isCancelled { return }
        await inputAssembler.updateCameraFrame(
          jpegData: frame.jpegData,
          timestamp: frame.timestamp
        )
      }
    }
    audioChunkTask = Task { [weak self] in
      guard let self else { return }
      do {
        for await chunk in audioCapture.chunks {
          if Task.isCancelled { return }
          let frame = try await inputAssembler.makeFrame(
            audioPCM: chunk.pcmFloat32
          )
          try await backendClient?.append(frame)
        }
      } catch {
        if !Task.isCancelled {
          await fail(error)
        }
      }
    }
  }

  private func stopMediaTasks() {
    cameraFrameTask?.cancel()
    cameraFrameTask = nil
    audioChunkTask?.cancel()
    audioChunkTask = nil
  }

  private func stopMedia() async {
    audioCapture.stop()
    audioPlayback.stop()
    await cameraCapture.stop()
  }

  private func fail(_ error: Error) async {
    stopMediaTasks()
    await stopMedia()
    await backendClient?.cancel()
    backendClient = nil
    await engineSupervisor?.stop()
    engineSupervisor = nil
    runtimeStatus = "Runtime failed"
    sessionState = .failed
    errorMessage = error.localizedDescription
  }

  private func authorizeMicrophone() async throws {
    switch authorization.microphonePermission() {
    case .authorized:
      return
    case .notDetermined:
      guard await authorization.requestMicrophone() else {
        throw AudioCaptureError.permissionDenied
      }
    case .denied, .restricted:
      throw AudioCaptureError.permissionDenied
    }
  }

  private func authorizeCamera() async throws {
    switch authorization.cameraPermission() {
    case .authorized:
      return
    case .notDetermined:
      guard await authorization.requestCamera() else {
        throw CameraCaptureError.permissionDenied
      }
    case .denied, .restricted:
      throw CameraCaptureError.permissionDenied
    }
  }
}

private enum LiveSetupError: Error, LocalizedError {
  case missingDevelopmentConfiguration
  case noRunnableModel(String)

  var errorDescription: String? {
    switch self {
    case .missingDevelopmentConfiguration:
      "Set COMNI_MODEL_DIR and COMNI_SERVER_PATH before starting Live."
    case .noRunnableModel(let path):
      "No runnable MiniCPM-o model bundle was found at \(path)."
    }
  }
}
