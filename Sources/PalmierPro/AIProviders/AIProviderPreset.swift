import Foundation

enum AIProviderPreset: String, CaseIterable, Identifiable, Sendable {
    case openAIResponses
    case openAIChatCompletions
    case anthropicMessages
    case falQueue
    case openAIMedia
    case compatibleGeneration

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openAIResponses: "OpenAI Responses"
        case .openAIChatCompletions: "OpenAI Chat Completions"
        case .anthropicMessages: "Anthropic Messages"
        case .falQueue: "fal.ai Generation"
        case .openAIMedia: "OpenAI Media Generation"
        case .compatibleGeneration: "Compatible Generation v1"
        }
    }

    func makeProfile() -> AIProviderProfile {
        switch self {
        case .openAIResponses:
            return AIProviderProfile(
                name: "OpenAI Responses",
                baseURL: AgentWireProtocol.openAIResponses.defaultBaseURL,
                auth: ProviderAuthConfiguration(kind: .bearer),
                agent: AgentEndpointConfiguration(
                    wireProtocol: .openAIResponses,
                    defaultModelID: "gpt-5.6-terra",
                    models: [
                        AgentModelOption(modelID: "gpt-5.6-terra", displayName: "GPT-5.6 Terra"),
                        AgentModelOption(modelID: "gpt-5.6-sol", displayName: "GPT-5.6 Sol"),
                        AgentModelOption(modelID: "gpt-5.6-luna", displayName: "GPT-5.6 Luna"),
                    ]
                )
            )

        case .openAIChatCompletions:
            return AIProviderProfile(
                name: "OpenAI Chat Completions",
                baseURL: AgentWireProtocol.openAIChatCompletions.defaultBaseURL,
                auth: ProviderAuthConfiguration(kind: .bearer),
                agent: AgentEndpointConfiguration(
                    wireProtocol: .openAIChatCompletions,
                    defaultModelID: "chat-latest",
                    models: [
                        AgentModelOption(modelID: "chat-latest", displayName: "Chat Latest"),
                        AgentModelOption(modelID: "gpt-5.6-terra", displayName: "GPT-5.6 Terra"),
                    ]
                )
            )

        case .anthropicMessages:
            return AIProviderProfile(
                name: "Anthropic",
                baseURL: AgentWireProtocol.anthropicMessages.defaultBaseURL,
                auth: ProviderAuthConfiguration(kind: .xAPIKey),
                agent: AgentEndpointConfiguration(
                    wireProtocol: .anthropicMessages,
                    defaultModelID: AnthropicModel.sonnet5.rawValue,
                    models: AnthropicModel.allCases.map {
                        AgentModelOption(modelID: $0.rawValue, displayName: $0.displayName)
                    },
                    additionalBody: AnthropicModel.sonnet5.requestExtras
                )
            )

        case .falQueue:
            return AIProviderProfile(
                name: "fal.ai",
                baseURL: "https://queue.fal.run",
                auth: ProviderAuthConfiguration(
                    kind: .customHeader,
                    headerName: "Authorization",
                    valuePrefix: "Key "
                ),
                generation: GenerationEndpointConfiguration(providerKind: .falQueue)
            )

        case .openAIMedia:
            return AIProviderProfile(
                name: "OpenAI Media",
                baseURL: "https://api.openai.com/v1",
                auth: ProviderAuthConfiguration(kind: .bearer),
                generation: GenerationEndpointConfiguration(providerKind: .openAIMedia)
            )

        case .compatibleGeneration:
            return AIProviderProfile(
                name: "Compatible Generation",
                baseURL: "http://localhost:8787",
                auth: ProviderAuthConfiguration(kind: .bearer),
                generation: GenerationEndpointConfiguration(
                    providerKind: .compatibleV1,
                    endpointPath: "v1"
                )
            )
        }
    }
}
