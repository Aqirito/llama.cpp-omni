import Darwin
import Foundation

public enum LoopbackPortError: Error, LocalizedError {
  case socketCreationFailed
  case bindFailed
  case addressLookupFailed
  case insufficientPorts

  public var errorDescription: String? {
    switch self {
    case .socketCreationFailed:
      "Could not create a loopback socket."
    case .bindFailed:
      "Could not bind a temporary loopback socket."
    case .addressLookupFailed:
      "Could not read the allocated loopback port."
    case .insufficientPorts:
      "Could not allocate enough distinct loopback ports."
    }
  }
}

public struct LoopbackPortAllocator: Sendable {
  public init() {}

  public func allocate(count: Int) throws -> [Int] {
    guard count > 0 else {
      return []
    }

    var ports = Set<Int>()
    var attempts = 0
    while ports.count < count, attempts < count * 4 {
      ports.insert(try allocateOne())
      attempts += 1
    }
    guard ports.count == count else {
      throw LoopbackPortError.insufficientPorts
    }
    return Array(ports)
  }

  public func isAvailable(_ port: Int) -> Bool {
    guard (1...65_535).contains(port) else {
      return false
    }
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      return false
    }
    defer { close(descriptor) }

    var address = loopbackAddress(port: UInt16(port))
    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(
          descriptor,
          $0,
          socklen_t(MemoryLayout<sockaddr_in>.size)
        ) == 0
      }
    }
  }

  private func allocateOne() throws -> Int {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw LoopbackPortError.socketCreationFailed
    }
    defer { close(descriptor) }

    var address = loopbackAddress(port: 0)
    let didBind = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(
          descriptor,
          $0,
          socklen_t(MemoryLayout<sockaddr_in>.size)
        ) == 0
      }
    }
    guard didBind else {
      throw LoopbackPortError.bindFailed
    }

    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let didRead = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &length) == 0
      }
    }
    guard didRead else {
      throw LoopbackPortError.addressLookupFailed
    }
    return Int(UInt16(bigEndian: address.sin_port))
  }

  private func loopbackAddress(port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    return address
  }
}
