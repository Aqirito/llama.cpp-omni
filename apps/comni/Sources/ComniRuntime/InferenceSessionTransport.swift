import ComniDomain
import Foundation

public protocol InferenceSessionTransport: Sendable {
  func connect(
    configuration: LiveSessionConfiguration
  ) async throws -> AsyncThrowingStream<LiveSessionEvent, Error>

  func append(_ frame: LiveInputFrame) async throws
  func appendChat(_ request: ChatRequest) async throws
  func close(reason: String) async throws
  func cancel() async
}

extension OmniBackendClient: InferenceSessionTransport {}

public enum InferenceEndpoint: Equatable, Sendable {
  case localBackend(URL)
  case realtimeGateway(URL)
}
