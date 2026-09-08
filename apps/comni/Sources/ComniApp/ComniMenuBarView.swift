import AppKit
import SwiftUI

struct ComniMenuBarView: View {
  @Bindable var model: WebManagerViewModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Text(model.summary)
    Divider()

    if model.isRunning {
      Button("Open Web App") {
        model.openWeb()
      }
      Button("Stop Services") {
        Task {
          await model.stop()
        }
      }
    } else if model.isConfigured {
      Button(model.isBusy ? "Starting..." : "Start Web App") {
        Task {
          await model.start()
        }
      }
      .disabled(model.isBusy)
    } else {
      Button("Configure Comni...") {
        openManager()
      }
    }

    Divider()
    Button("Open Manager") {
      openManager()
    }
    Button("Show Logs") {
      Task {
        await model.showLogs()
      }
    }

    Divider()
    Button("Quit Comni") {
      Task {
        await model.stop()
        NSApplication.shared.terminate(nil)
      }
    }
  }

  private func openManager() {
    openWindow(id: "manager")
    NSApplication.shared.activate(ignoringOtherApps: true)
  }
}
