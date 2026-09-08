import Foundation
import Testing

@testable import ComniRuntime

@Test
func runtimeLogStorePersistsEngineOutput() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let fileURL = root.appendingPathComponent("runtime.log")
  let store = RuntimeLogStore(fileURL: fileURL)
  await store.append(source: "engine", message: "server ready")

  let content = try String(contentsOf: fileURL, encoding: .utf8)
  #expect(content.contains("[engine] server ready"))
}
