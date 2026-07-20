import Foundation

enum AgentConnectionTester {
    static func test(
        runtimeProfile: AIProviderRuntimeProfile,
        transport: any AIHTTPTransporting = AIURLSessionTransport.shared
    ) async throws {
        guard let configuration = runtimeProfile.profile.agent else {
            throw AIProviderError.invalidConfiguration(
                "The selected provider does not configure an Agent service."
            )
        }
        let client = try AgentClientFactory.make(runtimeProfile: runtimeProfile, transport: transport)
        let request = AgentRequest(
            model: configuration.defaultModelID,
            maxOutputTokens: min(configuration.maxOutputTokens, 16),
            system: "This is a connection test. Reply with OK and do not call tools.",
            tools: [],
            messages: [AgentConversationMessage(role: .user, content: [.text("Reply with OK.")])],
            additionalBody: configuration.additionalBody
        )

        var receivedResponse = false
        for try await event in client.stream(request: request) {
            try Task.checkCancellation()
            switch event {
            case .textDelta(let text) where !text.isEmpty:
                receivedResponse = true
            case .finish:
                receivedResponse = true
            case .toolCallComplete:
                throw AIProviderError.invalidResponse("Connection test unexpectedly requested a tool.")
            case .usage, .textDelta:
                break
            }
            if receivedResponse { return }
        }
        throw AIProviderError.invalidResponse("Connection test ended without a response.")
    }
}
