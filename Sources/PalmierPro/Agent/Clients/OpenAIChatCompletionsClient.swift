import Foundation

struct OpenAIChatCompletionsClient: AgentClient {
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
              configuration.wireProtocol == .openAIChatCompletions else {
            throw AIProviderError.invalidConfiguration(
                "This provider is not configured for OpenAI Chat Completions."
            )
        }

        let endpoint = try AIProviderEndpoint.resolve(
            baseURL: runtimeProfile.profile.baseURL,
            endpointPath: configuration.endpointPath,
            allowInsecureHTTP: runtimeProfile.profile.allowInsecureHTTP
        )
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.applyProviderHeaders(runtimeProfile)
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: OpenAIChatCompletionsRequestBody.build(request: request),
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
        var decoder = OpenAIChatCompletionsStreamDecoder()
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
