import Foundation

// Legacy presets retained while the settings UI migrates to provider-owned free-form model IDs.
enum AnthropicModel: String, CaseIterable, Sendable {
    case sonnet5 = "claude-sonnet-5"
    case opus48 = "claude-opus-4-8"
    case haiku45 = "claude-haiku-4-5-20251001"

    var displayName: String {
        switch self {
        case .sonnet5: "Sonnet 5"
        case .opus48: "Opus 4.8"
        case .haiku45: "Haiku 4.5"
        }
    }

    var requestExtras: [String: JSONValue] {
        switch self {
        case .sonnet5: ["output_config": .object(["effort": .string("low")])]
        default: [:]
        }
    }
}

enum AgentFinishReason: Sendable, Equatable {
    case completed
    case toolCalls
    case maxOutputTokens
    case stopSequence
    case paused
    case refusal
    case other(String?)
}

struct AgentUsage: Sendable, Equatable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cachedInputTokens: Int?
    var cacheCreationInputTokens: Int?
}

struct AgentToolDefinition: Sendable, Equatable {
    let name: String
    let description: String
    let inputSchema: JSONValue
}

struct AgentConversationMessage: Sendable, Equatable {
    enum Role: String, Sendable {
        case user
        case assistant
    }

    let role: Role
    let content: [AgentInputBlock]
}

enum AgentToolResultBlock: Sendable, Equatable {
    case text(String)
    case image(base64: String, mimeType: String)
}

enum AgentInputBlock: Sendable, Equatable {
    case text(String)
    case image(base64: String, mimeType: String)
    case toolCall(id: String, name: String, inputJSON: String)
    case toolResult(toolCallID: String, content: [AgentToolResultBlock], isError: Bool)
}

struct AgentRequest: Sendable, Equatable {
    let model: String
    let maxOutputTokens: Int
    let system: String
    let tools: [AgentToolDefinition]
    let messages: [AgentConversationMessage]
    let additionalBody: [String: JSONValue]
}

enum AgentStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case toolCallComplete(id: String, name: String, inputJSON: String)
    case finish(AgentFinishReason)
    case usage(AgentUsage)
}

enum AIProviderError: LocalizedError, Sendable, Equatable {
    case invalidConfiguration(String)
    case missingCredential(String)
    case authenticationRequired(String)
    case paymentRequired(String)
    case rateLimited(String, retryAfterSeconds: Double?)
    case unsupportedContent(String)
    case httpError(status: Int)
    case invalidResponse(String)
    case streamError(String)
    case transport(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): message
        case .missingCredential(let message): message
        case .authenticationRequired(let message): message
        case .paymentRequired(let message): message
        case .rateLimited(let message, _): message
        case .unsupportedContent(let message): message
        case .httpError(let status): "AI provider request failed with HTTP \(status)."
        case .invalidResponse(let message): "Invalid AI provider response: \(message)"
        case .streamError(let message): "AI provider stream failed: \(message)"
        case .transport(let message): "AI provider connection failed: \(message)"
        case .cancelled: "AI provider request was cancelled."
        }
    }

    static func fromHTTP(status: Int, retryAfter: String? = nil) -> AIProviderError {
        switch status {
        case 401, 403:
            .authenticationRequired("The selected AI provider rejected its credentials.")
        case 402:
            .paymentRequired("The selected AI provider requires payment or additional credits.")
        case 429:
            .rateLimited(
                "The selected AI provider is rate limited. Try again shortly.",
                retryAfterSeconds: retryAfter.flatMap(Double.init)
            )
        default:
            .httpError(status: status)
        }
    }
}

protocol AgentClient: Sendable {
    func stream(request: AgentRequest) -> AsyncThrowingStream<AgentStreamEvent, Error>
}

enum AgentUsageLog {
    static func record(_ usage: AgentUsage) {
        #if DEBUG
        let input = usage.inputTokens ?? 0
        let cacheWrite = usage.cacheCreationInputTokens ?? 0
        let cacheRead = usage.cachedInputTokens ?? 0
        let billed = input + cacheWrite + cacheRead
        let readPercent = billed > 0 ? Int((Double(cacheRead) / Double(billed)) * 100) : 0
        print("[agent cache] input=\(input) cacheWrite=\(cacheWrite) cacheRead=\(cacheRead) (\(readPercent)% read)")
        #endif
    }
}

enum AgentStreamSupport {
    static func collectErrorText(
        from lines: AsyncThrowingStream<String, Error>,
        maxCharacters: Int = 4_096
    ) async throws -> String {
        var result = ""
        for try await line in lines {
            if result.count >= maxCharacters { break }
            let remaining = maxCharacters - result.count
            result += String(line.prefix(remaining))
            result += "\n"
        }
        return result
    }

    static func jsonObject(from inputJSON: String) throws -> [String: Any] {
        guard let data = inputJSON.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIProviderError.invalidConfiguration("Tool call arguments are not a JSON object.")
        }
        return object
    }
}
