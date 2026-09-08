import ComniDomain
import Foundation

public enum OmniBackendClientError: Error, LocalizedError {
  case alreadyConnected
  case notConnected
  case sessionNotReady
  case invalidEndpoint
  case unexpectedMessage
  case closeFailed(statusCode: Int)

  public var errorDescription: String? {
    switch self {
    case .alreadyConnected:
      "The Omni backend client is already connected."
    case .notConnected:
      "The Omni backend client is not connected."
    case .sessionNotReady:
      "The Omni backend session is not ready."
    case .invalidEndpoint:
      "The Omni backend endpoint is invalid."
    case .unexpectedMessage:
      "The Omni backend returned an unsupported WebSocket message."
    case .closeFailed(let statusCode):
      "The Omni backend rejected close with HTTP \(statusCode)."
    }
  }
}

public actor OmniBackendClient {
  private let baseURL: URL
  private let codec: BackendProtocolCodec
  private let urlSession: URLSession

  private var socket: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var continuation: AsyncThrowingStream<LiveSessionEvent, Error>.Continuation?
  private var sessionID: String?
  private var isClosing = false

  public init(
    baseURL: URL,
    urlSession: URLSession = .shared,
    codec: BackendProtocolCodec = BackendProtocolCodec()
  ) {
    self.baseURL = baseURL
    self.urlSession = urlSession
    self.codec = codec
  }

  public func connect(
    configuration: LiveSessionConfiguration
  ) async throws -> AsyncThrowingStream<LiveSessionEvent, Error> {
    guard socket == nil else {
      throw OmniBackendClientError.alreadyConnected
    }
    guard let webSocketURL = webSocketURL() else {
      throw OmniBackendClientError.invalidEndpoint
    }

    let pair = AsyncThrowingStream<LiveSessionEvent, Error>.makeStream()
    continuation = pair.continuation
    isClosing = false
    sessionID = nil

    let task = urlSession.webSocketTask(with: webSocketURL)
    socket = task
    task.resume()
    continuation?.yield(.stateChanged(.preparing))

    do {
      let initMessage = try codec.encodeSessionInit(configuration)
      try await task.send(.string(initMessage))
    } catch {
      resetConnection()
      pair.continuation.finish(throwing: error)
      throw error
    }

    receiveTask = Task { [weak self] in
      await self?.receiveLoop()
    }
    return pair.stream
  }

  public func append(_ frame: LiveInputFrame) async throws {
    guard let socket else {
      throw OmniBackendClientError.notConnected
    }
    guard sessionID != nil else {
      throw OmniBackendClientError.sessionNotReady
    }

    let message = try codec.encodeInput(frame)
    try await socket.send(.string(message))
  }

  public func appendChat(_ request: ChatRequest) async throws {
    guard let socket else {
      throw OmniBackendClientError.notConnected
    }
    guard sessionID != nil else {
      throw OmniBackendClientError.sessionNotReady
    }

    let message = try codec.encodeChatRequest(request)
    try await socket.send(.string(message))
  }

  public func close(reason: String = "client_closed") async throws {
    guard socket != nil else {
      return
    }
    guard let sessionID else {
      cancelTransport()
      return
    }

    isClosing = true
    continuation?.yield(.stateChanged(.ending))

    let closeURL =
      baseURL
      .appendingPathComponent("sessions")
      .appendingPathComponent(sessionID)
      .appendingPathComponent("close")
    var request = URLRequest(url: closeURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.httpBody = try JSONEncoder().encode(CloseRequest(reason: reason))

    let (_, response) = try await urlSession.data(for: request)
    guard
      let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
      throw OmniBackendClientError.closeFailed(statusCode: statusCode)
    }

    continuation?.yield(.stateChanged(.ended))
    continuation?.yield(.ended(reason: reason))
    continuation?.finish()
    cancelTransport()
  }

  public func cancel() {
    isClosing = true
    continuation?.yield(.stateChanged(.ended))
    continuation?.yield(.ended(reason: "client_cancelled"))
    continuation?.finish()
    cancelTransport()
  }

  private func receiveLoop() async {
    do {
      while let socket {
        let message = try await socket.receive()
        let text: String
        switch message {
        case .string(let value):
          text = value
        case .data(let data):
          guard let value = String(data: data, encoding: .utf8) else {
            throw OmniBackendClientError.unexpectedMessage
          }
          text = value
        @unknown default:
          throw OmniBackendClientError.unexpectedMessage
        }

        let events = try codec.decodeEvent(text)
        for event in events {
          if case .sessionCreated(let id) = event {
            sessionID = id
          }
          continuation?.yield(event)
        }
      }
    } catch {
      if !isClosing {
        continuation?.yield(.stateChanged(.failed))
        continuation?.finish(throwing: error)
      } else {
        continuation?.finish()
      }
      resetConnection()
    }
  }

  private func webSocketURL() -> URL? {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
    else {
      return nil
    }
    switch components.scheme {
    case "http":
      components.scheme = "ws"
    case "https":
      components.scheme = "wss"
    default:
      return nil
    }
    let basePath =
      components.path.hasSuffix("/")
      ? String(components.path.dropLast()) : components.path
    components.path = "\(basePath)/backend"
    return components.url
  }

  private func cancelTransport() {
    receiveTask?.cancel()
    receiveTask = nil
    socket?.cancel(with: .normalClosure, reason: nil)
    resetConnection()
  }

  private func resetConnection() {
    socket = nil
    sessionID = nil
    continuation = nil
  }
}

private struct CloseRequest: Encodable {
  var reason: String
}
