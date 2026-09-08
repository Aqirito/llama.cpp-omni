import AppKit

@MainActor
final class ComniAppDelegate: NSObject, NSApplicationDelegate {
  weak var model: WebManagerViewModel?
  private var terminationPending = false

  func applicationShouldTerminate(
    _ sender: NSApplication
  ) -> NSApplication.TerminateReply {
    guard
      let model,
      model.isRunning || model.isBusy
    else {
      return .terminateNow
    }
    guard !terminationPending else {
      return .terminateLater
    }

    terminationPending = true
    Task {
      await model.stop()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
