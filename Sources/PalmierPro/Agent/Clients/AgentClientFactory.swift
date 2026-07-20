import Foundation

enum AgentClientFactory {
    static func make(
        runtimeProfile: AIProviderRuntimeProfile,
        transport: any AIHTTPTransporting = AIURLSessionTransport.shared
    ) throws -> any AgentClient {
        guard let configuration = runtimeProfile.profile.agent else {
            throw AIProviderError.invalidConfiguration(
                "The selected provider does not configure an Agent service."
            )
        }
        switch configuration.wireProtocol {
        case .anthropicMessages:
            return AnthropicClient(runtimeProfile: runtimeProfile, transport: transport)
        case .openAIResponses:
            return OpenAIResponsesClient(runtimeProfile: runtimeProfile, transport: transport)
        case .openAIChatCompletions:
            return OpenAIChatCompletionsClient(runtimeProfile: runtimeProfile, transport: transport)
        case .palmierManaged:
            return PalmierClient(runtimeProfile: runtimeProfile, transport: transport)
        }
    }
}
