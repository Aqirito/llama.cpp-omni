import AppKit
import ComniDomain
import ComniRuntime
import SwiftUI

@main
struct ComniApp: App {
  @NSApplicationDelegateAdaptor(ComniAppDelegate.self)
  private var appDelegate
  @State private var webManager = WebManagerViewModel()

  var body: some Scene {
    Window("Comni", id: "manager") {
      WebManagerView(model: webManager)
        .task {
          appDelegate.model = webManager
          if ProcessInfo.processInfo.environment["COMNI_AUTOSTART"] == "1",
            !webManager.isRunning,
            !webManager.isBusy
          {
            await webManager.start()
          }
        }
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 860, height: 720)

    MenuBarExtra {
      ComniMenuBarView(model: webManager)
    } label: {
      MenuBarBrandIcon()
    }

    Settings {
      Text("Configure model, Demo, server, and Python paths in the main window.")
        .padding(24)
        .frame(width: 440)
    }
  }
}

private enum AppScreen: String, Hashable {
  case chat
  case live
  case studio
  case library
}

private struct ComniHomeView: View {
  @State private var selectedScreen = AppScreen.chat
  @State private var model = LiveViewModel()
  @State private var chatModel = ChatViewModel()

  var body: some View {
    NavigationSplitView {
      List(selection: $selectedScreen) {
        Label("Chat", systemImage: "bubble.left.and.bubble.right")
          .tag(AppScreen.chat)
        Label("Live", systemImage: "waveform")
          .tag(AppScreen.live)
        Label("Studio", systemImage: "waveform.badge.mic")
          .tag(AppScreen.studio)
        Label("Library", systemImage: "square.stack.3d.up")
          .tag(AppScreen.library)
      }
      .navigationSplitViewColumnWidth(min: 180, ideal: 210)
      .safeAreaInset(edge: .top) {
        HStack(spacing: 10) {
          BrandIcon(size: 30)
          Text("Comni")
            .font(.headline)
          Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
      }
      .safeAreaInset(edge: .bottom) {
        HStack(spacing: 10) {
          Circle()
            .fill(.green)
            .frame(width: 7, height: 7)
          Text(activeRuntimeStatus)
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button {
            Task {
              let url = await RuntimeLogStore.shared.fileURL
              NSWorkspace.shared.activateFileViewerSelecting([url])
            }
          } label: {
            Image(systemName: "doc.text.magnifyingglass")
          }
          .buttonStyle(.borderless)
          .help("Show runtime log")
        }
        .padding()
      }
    } detail: {
      switch selectedScreen {
      case .chat:
        ChatView(model: chatModel)
      case .live:
        VStack(spacing: 0) {
          liveHeader
          Divider()
          HStack(spacing: 0) {
            liveStage
            if model.transcriptVisible {
              Divider()
              transcript
                .frame(width: 300)
            }
          }
        }
        .background(Color(nsColor: .windowBackgroundColor))
      case .studio:
        placeholder(
          title: "Studio",
          detail: "VoxCPM voice design and cloning will be added after Chat."
        )
      case .library:
        placeholder(
          title: "Library",
          detail: "Installed model discovery is ready; model management UI is next."
        )
      }
    }
    .alert("Live setup failed", isPresented: errorPresented) {
      Button("OK") {
        model.errorMessage = nil
      }
    } message: {
      Text(model.errorMessage ?? "Unknown error")
    }
    .onDisappear {
      Task {
        await model.stop()
        await chatModel.stop()
      }
    }
    .onChange(of: selectedScreen) { previous, _ in
      Task {
        if previous == .chat {
          await chatModel.stop()
        } else if previous == .live {
          await model.stop()
        }
      }
    }
  }

  private var liveHeader: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Omni Live")
          .font(.headline)
        Text("MiniCPM-o 4.5")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Label(stateLabel, systemImage: stateSymbol)
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)
      Button {
        model.transcriptVisible.toggle()
      } label: {
        Image(systemName: "sidebar.trailing")
      }
      .buttonStyle(.borderless)
      .help("Toggle transcript")
    }
    .padding(.horizontal, 20)
    .frame(height: 58)
  }

  private var liveStage: some View {
    ZStack {
      Color.black

      if model.cameraEnabled && isPreparingOrReady {
        CameraPreview(
          session: model.cameraCapture.session,
          mirrored: model.cameraMirrored
        )
        .ignoresSafeArea()
      } else {
        VStack(spacing: 14) {
          Image(
            systemName: model.cameraEnabled
              ? "camera.fill" : "camera.slash.fill"
          )
          .font(.system(size: 32, weight: .light))
          .foregroundStyle(.white.opacity(0.72))
          Text(model.cameraEnabled ? "Camera preview" : "Camera is off")
            .font(.callout)
            .foregroundStyle(.white.opacity(0.72))
        }
      }

      VStack {
        Spacer()
        HStack(spacing: 12) {
          controlButton(
            symbol: model.microphoneEnabled ? "mic.fill" : "mic.slash.fill",
            label: model.microphoneEnabled ? "Mute" : "Unmute"
          ) {
            Task {
              await model.toggleMicrophone()
            }
          }
          controlButton(
            symbol: model.cameraEnabled ? "video.fill" : "video.slash.fill",
            label: model.cameraEnabled ? "Camera off" : "Camera on"
          ) {
            Task {
              await model.toggleCamera()
            }
          }
          controlButton(
            symbol: "arrow.triangle.2.circlepath.camera",
            label: "Switch camera"
          ) {
            Task {
              await model.switchCamera()
            }
          }

          Button {
            Task {
              if isInactive {
                await model.startLive()
              } else {
                await model.stop()
              }
            }
          } label: {
            Label(
              isInactive ? "Prepare Live" : "End",
              systemImage: isInactive ? "play.fill" : "phone.down.fill"
            )
            .frame(minWidth: 88)
          }
          .buttonStyle(.borderedProminent)
          .tint(isInactive ? .accentColor : .red)
          .controlSize(.large)
        }
        .padding(12)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 24)
      }
    }
  }

  private var transcript: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Transcript")
        .font(.headline)
      if model.transcript.isEmpty {
        ContentUnavailableView(
          "No live session",
          systemImage: "captions.bubble",
          description: Text("Model speech and live captions will appear here.")
        )
      } else {
        ScrollView {
          Text(model.transcript)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      Spacer()
    }
    .padding(18)
    .background(.background)
  }

  private func controlButton(
    symbol: String,
    label: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(label, systemImage: symbol)
        .labelStyle(.iconOnly)
        .frame(width: 24, height: 24)
    }
    .buttonStyle(.bordered)
    .controlSize(.large)
    .help(label)
  }

  private var activeRuntimeStatus: String {
    switch selectedScreen {
    case .chat:
      chatModel.runtimeStatus
    case .live:
      model.runtimeStatus
    case .studio, .library:
      "Runtime not connected"
    }
  }

  private func placeholder(title: String, detail: String) -> some View {
    ContentUnavailableView(
      title,
      systemImage: "hammer",
      description: Text(detail)
    )
  }

  private var stateLabel: String {
    switch model.sessionState {
    case .idle:
      "Ready to start"
    case .preparing:
      "Preparing"
    case .ready:
      "Ready"
    case .listening:
      "Listening"
    case .speaking:
      "Speaking"
    case .paused:
      "Paused"
    case .ending:
      "Ending"
    case .ended:
      "Ended"
    case .failed:
      "Failed"
    }
  }

  private var stateSymbol: String {
    switch model.sessionState {
    case .listening:
      "ear"
    case .speaking:
      "waveform"
    case .failed:
      "exclamationmark.triangle"
    default:
      "circle.fill"
    }
  }

  private var isInactive: Bool {
    switch model.sessionState {
    case .idle, .ended, .failed:
      true
    default:
      false
    }
  }

  private var isPreparingOrReady: Bool {
    switch model.sessionState {
    case .preparing, .ready, .listening, .speaking, .paused:
      true
    default:
      false
    }
  }

  private var errorPresented: Binding<Bool> {
    Binding(
      get: { model.errorMessage != nil },
      set: { isPresented in
        if !isPresented {
          model.errorMessage = nil
        }
      }
    )
  }
}
