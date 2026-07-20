@preconcurrency import Foundation

struct AIHTTPDataResponse: Sendable {
    let data: Data
    let response: HTTPURLResponse
}

struct AIHTTPLineResponse: Sendable {
    let response: HTTPURLResponse
    let lines: AsyncThrowingStream<String, Error>
    let cancel: @Sendable () -> Void

    init(
        response: HTTPURLResponse,
        lines: AsyncThrowingStream<String, Error>,
        cancel: @escaping @Sendable () -> Void = {}
    ) {
        self.response = response
        self.lines = lines
        self.cancel = cancel
    }
}

protocol AIHTTPTransporting: Sendable {
    func data(for request: URLRequest, maxResponseBytes: Int) async throws -> AIHTTPDataResponse
    func lines(for request: URLRequest) async throws -> AIHTTPLineResponse
}

enum AIHTTPTransportError: LocalizedError, Equatable {
    case nonHTTPResponse
    case responseTooLarge(Int)
    case streamLineTooLarge(Int)
    case invalidStreamEncoding
    case crossOriginRedirect

    var errorDescription: String? {
        switch self {
        case .nonHTTPResponse: "Provider returned a non-HTTP response."
        case .responseTooLarge(let bytes): "Provider response exceeded the \(bytes)-byte limit."
        case .streamLineTooLarge(let bytes): "Provider stream line exceeded the \(bytes)-byte limit."
        case .invalidStreamEncoding: "Provider stream was not valid UTF-8."
        case .crossOriginRedirect: "Provider attempted to redirect credentials to another origin."
        }
    }
}

final class AIURLSessionTransport: NSObject, AIHTTPTransporting, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = AIURLSessionTransport()
    private static let maxStreamBytes = 16 * 1_024 * 1_024
    private static let maxStreamLineBytes = 1 * 1_024 * 1_024

    private let configuration: URLSessionConfiguration
    private lazy var session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)

    init(configuration: URLSessionConfiguration = .ephemeral) {
        let copy = configuration.copy() as? URLSessionConfiguration ?? configuration
        copy.httpShouldSetCookies = false
        copy.urlCredentialStorage = nil
        copy.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.configuration = copy
        super.init()
    }

    func data(for request: URLRequest, maxResponseBytes: Int = 4 * 1_024 * 1_024) async throws -> AIHTTPDataResponse {
        guard maxResponseBytes >= 0 else {
            throw AIHTTPTransportError.responseTooLarge(maxResponseBytes)
        }
        let (bytes, rawResponse) = try await session.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw AIHTTPTransportError.nonHTTPResponse
        }
        try validateRedirectResponse(response, originalURL: request.url)

        var data = Data()
        data.reserveCapacity(min(maxResponseBytes, 64 * 1_024))
        for try await byte in bytes {
            guard data.count < maxResponseBytes else {
                throw AIHTTPTransportError.responseTooLarge(maxResponseBytes)
            }
            data.append(byte)
        }
        return AIHTTPDataResponse(data: data, response: response)
    }

    func lines(for request: URLRequest) async throws -> AIHTTPLineResponse {
        let (bytes, rawResponse) = try await session.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw AIHTTPTransportError.nonHTTPResponse
        }
        try validateRedirectResponse(response, originalURL: request.url)

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: String.self)
        let task = Task {
            do {
                var totalBytes = 0
                var line = Data()
                line.reserveCapacity(512)

                func emitLine() throws {
                    if line.last == 0x0D {
                        line.removeLast()
                    }
                    guard let value = String(data: line, encoding: .utf8) else {
                        throw AIHTTPTransportError.invalidStreamEncoding
                    }
                    continuation.yield(value)
                    line.removeAll(keepingCapacity: true)
                }

                for try await byte in bytes {
                    try Task.checkCancellation()
                    totalBytes += 1
                    guard totalBytes <= Self.maxStreamBytes else {
                        throw AIHTTPTransportError.responseTooLarge(Self.maxStreamBytes)
                    }
                    if byte == 0x0A {
                        try emitLine()
                    } else {
                        guard line.count < Self.maxStreamLineBytes else {
                            throw AIHTTPTransportError.streamLineTooLarge(Self.maxStreamLineBytes)
                        }
                        line.append(byte)
                    }
                }
                if !line.isEmpty {
                    try emitLine()
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return AIHTTPLineResponse(
            response: response,
            lines: stream,
            cancel: { task.cancel() }
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let sourceURL = response.url, let destinationURL = request.url,
              AIProviderEndpoint.sameOrigin(sourceURL, destinationURL) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private func validateRedirectResponse(_ response: HTTPURLResponse, originalURL: URL?) throws {
        guard (300..<400).contains(response.statusCode),
              let location = response.value(forHTTPHeaderField: "Location"),
              let sourceURL = response.url ?? originalURL,
              let destinationURL = URL(string: location, relativeTo: sourceURL)?.absoluteURL,
              !AIProviderEndpoint.sameOrigin(sourceURL, destinationURL) else { return }
        throw AIHTTPTransportError.crossOriginRedirect
    }
}

extension URLRequest {
    mutating func applyProviderHeaders(_ runtimeProfile: AIProviderRuntimeProfile) {
        for (name, value) in runtimeProfile.headers {
            setValue(value, forHTTPHeaderField: name)
        }
    }
}
