import Foundation

struct OpenAIChatCompletionsStreamDecoder: Sendable {
    private struct PendingToolCall {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""
        var emitted: Bool = false
    }

    private var pendingTools: [Int: PendingToolCall] = [:]

    mutating func decode(_ serverEvent: SSEEvent) throws -> [AgentStreamEvent] {
        let trimmed = serverEvent.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "[DONE]" {
            return []
        }

        let object: Any
        do {
            guard let data = serverEvent.data.data(using: .utf8) else {
                throw AIProviderError.invalidResponse("OpenAI Chat Completions stream event is not valid UTF-8.")
            }
            object = try JSONSerialization.jsonObject(with: data)
        } catch let error as AIProviderError {
            throw error
        } catch {
            throw AIProviderError.invalidResponse("OpenAI Chat Completions stream event is not valid JSON.")
        }

        guard let event = object as? [String: Any] else {
            throw AIProviderError.invalidResponse("OpenAI Chat Completions stream event is not a JSON object.")
        }

        if let error = event["error"] as? [String: Any] {
            throw AIProviderError.streamError(Self.errorCode(from: error))
        }

        var events: [AgentStreamEvent] = []

        if let choices = event["choices"] as? [[String: Any]] {
            for choice in choices {
                if let delta = choice["delta"] as? [String: Any] {
                    if let content = delta["content"] as? String, !content.isEmpty {
                        events.append(.textDelta(content))
                    }
                    if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                        for toolCall in toolCalls {
                            accumulate(toolCall)
                        }
                    }
                }

                if let finishReason = choice["finish_reason"] as? String {
                    events.append(contentsOf: completePendingToolCalls())
                    events.append(.finish(Self.finishReason(finishReason)))
                }
            }
        }

        if let usage = event["usage"] as? [String: Any] {
            let promptDetails = usage["prompt_tokens_details"] as? [String: Any]
            let value = AgentUsage(
                inputTokens: Self.intValue(usage["input_tokens"]) ?? Self.intValue(usage["prompt_tokens"]),
                outputTokens: Self.intValue(usage["output_tokens"]) ?? Self.intValue(usage["completion_tokens"]),
                cachedInputTokens: Self.intValue(promptDetails?["cached_tokens"]),
                cacheCreationInputTokens: nil
            )
            AgentUsageLog.record(value)
            events.append(.usage(value))
        }

        return events
    }

    private mutating func accumulate(_ toolCall: [String: Any]) {
        guard let index = Self.intValue(toolCall["index"]) else { return }
        var pending = pendingTools[index] ?? PendingToolCall()
        if let id = toolCall["id"] as? String {
            pending.id += id
        }
        if let function = toolCall["function"] as? [String: Any] {
            if let name = function["name"] as? String {
                pending.name += name
            }
            if let arguments = function["arguments"] as? String {
                pending.arguments += arguments
            }
        }
        pendingTools[index] = pending
    }

    private static func intValue(_ raw: Any?) -> Int? {
        switch raw {
        case let value as Int: value
        case let value as NSNumber: value.intValue
        default: nil
        }
    }

    private mutating func completePendingToolCalls() -> [AgentStreamEvent] {
        var events: [AgentStreamEvent] = []
        for index in pendingTools.keys.sorted() {
            guard var pending = pendingTools[index], !pending.emitted else { continue }
            pending.emitted = true
            pendingTools[index] = pending
            events.append(.toolCallComplete(
                id: pending.id,
                name: pending.name,
                inputJSON: pending.arguments.isEmpty ? "{}" : pending.arguments
            ))
        }
        return events
    }

    private static func finishReason(_ rawValue: String) -> AgentFinishReason {
        switch rawValue {
        case "stop": .completed
        case "tool_calls": .toolCalls
        case "length": .maxOutputTokens
        case "content_filter": .refusal
        default: .other(rawValue)
        }
    }

    private static func errorCode(from error: [String: Any]) -> String {
        if let type = error["type"] as? String, !type.isEmpty {
            return type
        }
        if let code = error["code"] as? String, !code.isEmpty {
            return code
        }
        if let code = error["code"] as? Int {
            return String(code)
        }
        return "provider_error"
    }
}

enum OpenAIChatCompletionsRequestBody {
    static func build(request: AgentRequest) throws -> [String: Any] {
        var messages: [[String: Any]] = [
            ["role": "system", "content": request.system],
        ]
        for message in request.messages {
            try append(message: message, into: &messages)
        }

        var body: [String: Any] = [
            "model": request.model,
            "stream": true,
            "max_tokens": request.maxOutputTokens,
            "stream_options": ["include_usage": true],
            "messages": messages,
        ]

        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.inputSchema.foundationValue,
                    ] as [String: Any],
                ] as [String: Any]
            }
        }

        for (key, value) in request.additionalBody {
            body[key] = value.foundationValue
        }
        return body
    }

    private static func append(
        message: AgentConversationMessage,
        into messages: inout [[String: Any]]
    ) throws {
        var contentItems: [[String: Any]] = []
        var toolCalls: [[String: Any]] = []

        func flushOrdinary() {
            switch message.role {
            case .user:
                guard !contentItems.isEmpty else { return }
                messages.append([
                    "role": "user",
                    "content": contentItems,
                ])
                contentItems.removeAll(keepingCapacity: true)

            case .assistant:
                guard !contentItems.isEmpty || !toolCalls.isEmpty else { return }
                var encoded: [String: Any] = ["role": "assistant"]
                if contentItems.isEmpty {
                    encoded["content"] = NSNull()
                } else {
                    encoded["content"] = contentItems
                }
                if !toolCalls.isEmpty {
                    encoded["tool_calls"] = toolCalls
                }
                messages.append(encoded)
                contentItems.removeAll(keepingCapacity: true)
                toolCalls.removeAll(keepingCapacity: true)
            }
        }

        for block in message.content {
            switch block {
            case .text(let text):
                guard !text.isEmpty else { continue }
                contentItems.append(["type": "text", "text": text])

            case .image(let base64, let mimeType):
                guard message.role == .user else {
                    throw AIProviderError.unsupportedContent(
                        "OpenAI Chat Completions does not support assistant image content."
                    )
                }
                contentItems.append([
                    "type": "image_url",
                    "image_url": [
                        "url": "data:\(mimeType);base64,\(base64)",
                    ],
                ])

            case .toolCall(let id, let name, let inputJSON):
                guard message.role == .assistant else { continue }
                toolCalls.append([
                    "id": id,
                    "type": "function",
                    "function": [
                        "name": name,
                        "arguments": inputJSON,
                    ] as [String: Any],
                ])

            case .toolResult(let toolCallID, let content, let isError):
                guard message.role == .user else {
                    throw AIProviderError.invalidConfiguration(
                        "OpenAI Chat Completions tool results must use the user conversation role."
                    )
                }
                flushOrdinary()
                messages.append([
                    "role": "tool",
                    "tool_call_id": toolCallID,
                    "content": try toolResultText(content, isError: isError),
                ])
            }
        }

        flushOrdinary()
    }

    private static func toolResultText(
        _ content: [AgentToolResultBlock],
        isError: Bool
    ) throws -> String {
        var parts: [String] = []
        for block in content {
            switch block {
            case .text(let text):
                parts.append(text)
            case .image:
                throw AIProviderError.unsupportedContent(
                    "OpenAI Chat Completions does not support image tool results."
                )
            }
        }
        let text = parts.joined(separator: "\n")
        return isError ? "Tool error: \(text)" : text
    }
}
