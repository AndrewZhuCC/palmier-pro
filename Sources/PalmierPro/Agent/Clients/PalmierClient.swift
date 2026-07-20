import ClerkKit
import Foundation

struct PalmierClient: AgentClient {
    let runtimeProfile: AIProviderRuntimeProfile
    let transport: any AIHTTPTransporting

    init(
        runtimeProfile: AIProviderRuntimeProfile,
        transport: any AIHTTPTransporting = AIURLSessionTransport.shared
    ) {
        self.runtimeProfile = runtimeProfile
        self.transport = transport
    }

    func stream(request: AgentRequest) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request: request, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as AIProviderError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: AIProviderError.transport(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        request: AgentRequest,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws {
        guard let configuration = runtimeProfile.profile.agent,
              configuration.wireProtocol == .palmierManaged else {
            throw AIProviderError.invalidConfiguration("This provider is not configured for Palmier Cloud Agent.")
        }
        guard let clerkSession = await Clerk.shared.session, clerkSession.status == .active,
              let token = try await clerkSession.getToken(), !token.isEmpty else {
            throw AIProviderError.authenticationRequired("Sign in to use the Palmier Cloud AI agent.")
        }

        let endpoint = try AIProviderEndpoint.resolve(
            baseURL: runtimeProfile.profile.baseURL,
            endpointPath: configuration.endpointPath,
            allowInsecureHTTP: runtimeProfile.profile.allowInsecureHTTP
        )
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: AnthropicRequestBody.build(request: request),
            options: [.sortedKeys]
        )

        let response = try await transport.lines(for: urlRequest)
        defer { response.cancel() }
        guard response.response.statusCode < 400 else {
            let body = (try? await AgentStreamSupport.collectErrorText(from: response.lines)) ?? ""
            throw PalmierClientError.from(status: response.response.statusCode, body: body).providerError
        }

        var parser = SSEParser()
        var decoder = AnthropicStreamDecoder()
        try await withTaskCancellationHandler {
            for try await line in response.lines {
                try Task.checkCancellation()
                if let serverEvent = parser.consume(line: line) {
                    for event in try decoder.decode(serverEvent) {
                        continuation.yield(event)
                    }
                }
            }
            if let serverEvent = parser.finish() {
                for event in try decoder.decode(serverEvent) {
                    continuation.yield(event)
                }
            }
        } onCancel: {
            response.cancel()
        }
    }
}

enum PalmierClientError: LocalizedError {
    case unauthenticated
    case insufficientCredits(String)
    case upstream(String)

    var errorDescription: String? {
        switch self {
        case .unauthenticated: "Sign in to use the AI agent."
        case .insufficientCredits(let message): message
        case .upstream(let message): message
        }
    }

    var providerError: AIProviderError {
        switch self {
        case .unauthenticated:
            .authenticationRequired("Sign in to use the Palmier Cloud AI agent.")
        case .insufficientCredits(let message):
            .paymentRequired(message)
        case .upstream(let message):
            .transport(message)
        }
    }

    static func from(status: Int, body: String) -> PalmierClientError {
        let parsed = parseErrorEnvelope(body)
        switch parsed?.code {
        case "unauthenticated": return .unauthenticated
        case "insufficient_credits":
            return .insufficientCredits(parsed?.message ?? "Palmier Cloud requires additional credits.")
        default:
            if status == 401 { return .unauthenticated }
            if status == 402 {
                return .insufficientCredits(parsed?.message ?? "Palmier Cloud requires additional credits.")
            }
            return .upstream("Palmier Cloud agent request failed with HTTP \(status).")
        }
    }

    private static func parseErrorEnvelope(_ body: String) -> (code: String, message: String)? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let code = error["code"] as? String,
              let message = error["message"] as? String else { return nil }
        return (code, String(message.prefix(500)))
    }
}
