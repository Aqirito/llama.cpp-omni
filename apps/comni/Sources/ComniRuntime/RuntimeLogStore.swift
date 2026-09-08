import Foundation

public actor RuntimeLogStore {
  public static let shared = RuntimeLogStore()

  public let fileURL: URL
  private let maximumBytes: Int64

  public init(
    fileURL: URL? = nil,
    maximumBytes: Int64 = 5 * 1024 * 1024
  ) {
    self.fileURL =
      fileURL
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/Comni", isDirectory: true)
      .appendingPathComponent("runtime.log")
    self.maximumBytes = maximumBytes
  }

  public func append(source: String, message: String) {
    do {
      let fileManager = FileManager.default
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try rotateIfNeeded(fileManager: fileManager)
      if !fileManager.fileExists(atPath: fileURL.path) {
        fileManager.createFile(atPath: fileURL.path, contents: nil)
      }

      let timestamp = ISO8601DateFormatter().string(from: Date())
      let line = "\(timestamp) [\(source)] \(message)"
      guard let data = line.data(using: .utf8) else {
        return
      }
      let handle = try FileHandle(forWritingTo: fileURL)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
      if !line.hasSuffix("\n") {
        try handle.write(contentsOf: Data([0x0A]))
      }
    } catch {
      // Logging must never terminate an inference session.
    }
  }

  private func rotateIfNeeded(fileManager: FileManager) throws {
    guard
      let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
      let size = attributes[.size] as? NSNumber,
      size.int64Value >= maximumBytes
    else {
      return
    }

    let previousURL = fileURL.appendingPathExtension("previous")
    if fileManager.fileExists(atPath: previousURL.path) {
      try fileManager.removeItem(at: previousURL)
    }
    try fileManager.moveItem(at: fileURL, to: previousURL)
  }
}
