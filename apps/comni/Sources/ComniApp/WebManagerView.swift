import ComniRuntime
import SwiftUI

struct WebManagerView: View {
  @Bindable var model: WebManagerViewModel
  @State private var configurationExpanded = true

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        header
        statusPanel
        actions
        configurationPanel
        footer
      }
      .frame(maxWidth: 760)
      .padding(28)
      .frame(maxWidth: .infinity)
    }
    .frame(minWidth: 760, minHeight: 640)
    .background(Color(nsColor: .windowBackgroundColor))
    .alert("Unable to start Comni Web", isPresented: errorPresented) {
      Button("OK") {
        model.errorMessage = nil
      }
    } message: {
      Text(model.errorMessage ?? "Unknown error")
    }
  }

  private var header: some View {
    HStack(spacing: 16) {
      BrandIcon(size: 58)
      VStack(alignment: .leading, spacing: 5) {
        Text("Comni")
          .font(.largeTitle.weight(.semibold))
        Text("Local MiniCPM-o Web Runtime")
          .foregroundStyle(.secondary)
      }
      Spacer()
      statusBadge
    }
  }

  private var statusBadge: some View {
    HStack(spacing: 7) {
      Circle()
        .fill(model.isRunning ? Color.green : Color.secondary.opacity(0.45))
        .frame(width: 8, height: 8)
      Text(model.isRunning ? "Running" : "Stopped")
        .font(.callout.weight(.medium))
    }
    .padding(.horizontal, 11)
    .padding(.vertical, 7)
    .background(.quaternary.opacity(0.6), in: Capsule())
  }

  private var statusPanel: some View {
    GroupBox {
      VStack(spacing: 0) {
        componentRow(.frontend, title: "Mobile frontend")
        Divider()
        componentRow(.backend, title: "Inference backend")
        Divider()
        componentRow(.worker, title: "Runtime worker")
        Divider()
        componentRow(.gateway, title: "Web gateway")
      }
      .padding(.vertical, 2)
    } label: {
      VStack(alignment: .leading, spacing: 3) {
        Text("Services")
          .font(.headline)
        Text(model.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var actions: some View {
    HStack(spacing: 10) {
      if model.isRunning {
        Button("Open Web App") {
          model.openWeb()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)

        Button("Stop Services") {
          Task {
            await model.stop()
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
      } else {
        Button(model.isBusy ? "Starting..." : "Start Web App") {
          Task {
            await model.start()
          }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(model.isBusy)
      }

      Spacer()

      Button {
        Task {
          await model.showLogs()
        }
      } label: {
        Label("Logs", systemImage: "doc.text.magnifyingglass")
      }
      .buttonStyle(.bordered)
    }
  }

  private var configurationPanel: some View {
    DisclosureGroup("Configuration", isExpanded: $configurationExpanded) {
      VStack(spacing: 12) {
        pathRow(
          title: "Model bundle",
          text: $model.modelDirectory,
          action: model.chooseModelDirectory
        )
        pathRow(
          title: "Demo source",
          text: $model.demoDirectory,
          action: model.chooseDemoDirectory
        )
        pathRow(
          title: "Inference server",
          text: $model.serverPath,
          action: model.chooseServer
        )
        pathRow(
          title: "Python",
          text: $model.pythonPath,
          action: model.choosePython
        )
      }
      .padding(.top, 12)
    }
    .padding(16)
    .background(
      Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    .disabled(model.isRunning || model.isBusy)
  }

  private var footer: some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: "info.circle")
        .foregroundStyle(.secondary)
      Text(
        "Comni starts the verified MiniCPM-o Demo locally. Chat, voice, and camera interactions run in the browser; this window only manages services and logs."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
    }
  }

  private func componentRow(
    _ component: WebStackComponent,
    title: String
  ) -> some View {
    let state = model.componentStates[component] ?? .stopped
    return HStack(spacing: 11) {
      Circle()
        .fill(componentColor(state))
        .frame(width: 8, height: 8)
      Text(title)
      Spacer()
      Text(componentLabel(state))
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 11)
  }

  private func pathRow(
    title: String,
    text: Binding<String>,
    action: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 10) {
      Text(title)
        .frame(width: 112, alignment: .leading)
      TextField("", text: text)
        .textFieldStyle(.roundedBorder)
      Button("Choose...", action: action)
    }
  }

  private func componentLabel(_ state: EngineLifecycleState) -> String {
    switch state {
    case .stopped:
      "Stopped"
    case .starting:
      "Starting"
    case .loading:
      "Loading"
    case .ready:
      "Ready"
    case .stopping:
      "Stopping"
    case .failed:
      "Failed"
    }
  }

  private func componentColor(_ state: EngineLifecycleState) -> Color {
    switch state {
    case .ready:
      .green
    case .starting, .loading, .stopping:
      .orange
    case .failed:
      .red
    case .stopped:
      .secondary.opacity(0.4)
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
