import Foundation

extension Notification.Name {
    static let anthropicAPIKeyChanged = Notification.Name("anthropicAPIKeyChanged")
}

enum AnthropicKeychain {
    private static let account = "anthropic-api-key"

    static func save(_ key: String) {
        KeychainStore.save(key, account: account)
        NotificationCenter.default.post(name: .anthropicAPIKeyChanged, object: nil)
    }

    static func load() -> String? {
        #if DEBUG
        if let environmentKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentKey.isEmpty {
            return environmentKey
        }
        #endif
        return KeychainStore.load(account: account)
    }

    static func delete() {
        KeychainStore.delete(account: account)
        NotificationCenter.default.post(name: .anthropicAPIKeyChanged, object: nil)
    }
}

struct AnthropicClient: AgentClient {
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
              configuration.wireProtocol == .anthropicMessages else {
            throw AIProviderError.invalidConfiguration("This provider is not configured for Anthropic Messages.")
        }
        guard runtimeProfile.primaryCredential?.isEmpty == false else {
            throw AIProviderError.missingCredential("The selected Anthropic provider is missing its API key.")
        }

        let endpoint = try AIProviderEndpoint.resolve(
            baseURL: runtimeProfile.profile.baseURL,
            endpointPath: configuration.endpointPath,
            allowInsecureHTTP: runtimeProfile.profile.allowInsecureHTTP
        )
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.applyProviderHeaders(runtimeProfile)
        if urlRequest.value(forHTTPHeaderField: "anthropic-version") == nil {
            urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: AnthropicRequestBody.build(request: request),
            options: [.sortedKeys]
        )

        let response = try await transport.lines(for: urlRequest)
        defer { response.cancel() }
        guard response.response.statusCode < 400 else {
            _ = try? await AgentStreamSupport.collectErrorText(from: response.lines)
            throw AIProviderError.fromHTTP(
                status: response.response.statusCode,
                retryAfter: response.response.value(forHTTPHeaderField: "Retry-After")
            )
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
