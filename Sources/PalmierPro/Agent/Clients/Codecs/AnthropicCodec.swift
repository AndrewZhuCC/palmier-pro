import Foundation

struct AnthropicStreamDecoder: Sendable {
    private var pendingTools: [Int: (id: String, name: String, json: String)] = [:]

    mutating func decode(_ serverEvent: SSEEvent) throws -> [AgentStreamEvent] {
        guard let data = serverEvent.data.data(using: .utf8) else {
            throw AIProviderError.invalidResponse("Anthropic stream event is not valid JSON.")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AIProviderError.invalidResponse("Anthropic stream event is not valid JSON.")
        }
        guard let event = object as? [String: Any],
              let type = event["type"] as? String else {
            throw AIProviderError.invalidResponse("Anthropic stream event is not valid JSON.")
        }

        switch type {
        case "message_start":
            guard let message = event["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return [] }
            let value = AgentUsage(
                inputTokens: usage["input_tokens"] as? Int,
                outputTokens: usage["output_tokens"] as? Int,
                cachedInputTokens: usage["cache_read_input_tokens"] as? Int,
                cacheCreationInputTokens: usage["cache_creation_input_tokens"] as? Int
            )
            AgentUsageLog.record(value)
            return [.usage(value)]

        case "content_block_start":
            if let index = event["index"] as? Int,
               let block = event["content_block"] as? [String: Any],
               block["type"] as? String == "tool_use",
               let id = block["id"] as? String,
               let name = block["name"] as? String {
                let initialInput = block["input"] as? [String: Any]
                let initialJSON = initialInput.flatMap { object in
                    try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                pendingTools[index] = (id, name, initialJSON == "{}" ? "" : initialJSON)
            }
            return []

        case "content_block_delta":
            guard let index = event["index"] as? Int,
                  let delta = event["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String else { return [] }
            if deltaType == "text_delta", let text = delta["text"] as? String, !text.isEmpty {
                return [.textDelta(text)]
            }
            if deltaType == "input_json_delta",
               let partial = delta["partial_json"] as? String,
               var accumulated = pendingTools[index] {
                accumulated.json += partial
                pendingTools[index] = accumulated
            }
            return []

        case "content_block_stop":
            guard let index = event["index"] as? Int,
                  let accumulated = pendingTools.removeValue(forKey: index) else { return [] }
            return [.toolCallComplete(
                id: accumulated.id,
                name: accumulated.name,
                inputJSON: accumulated.json.isEmpty ? "{}" : accumulated.json
            )]

        case "message_delta":
            guard let delta = event["delta"] as? [String: Any],
                  let rawReason = delta["stop_reason"] as? String else { return [] }
            return [.finish(Self.finishReason(rawReason))]

        case "error":
            let error = event["error"] as? [String: Any]
            let errorType = error?["type"] as? String ?? "provider_error"
            throw AIProviderError.streamError(errorType)

        default:
            return []
        }
    }

    private static func finishReason(_ rawValue: String) -> AgentFinishReason {
        switch rawValue {
        case "end_turn": .completed
        case "tool_use": .toolCalls
        case "max_tokens": .maxOutputTokens
        case "stop_sequence": .stopSequence
        case "pause_turn": .paused
        case "refusal": .refusal
        default: .other(rawValue)
        }
    }
}

enum AnthropicRequestBody {
    static func build(request: AgentRequest) throws -> [String: Any] {
        var toolBlocks: [[String: Any]] = request.tools.map {
            [
                "name": $0.name,
                "description": $0.description,
                "input_schema": $0.inputSchema.foundationValue,
            ]
        }
        if var lastTool = toolBlocks.popLast() {
            lastTool["cache_control"] = ["type": "ephemeral"]
            toolBlocks.append(lastTool)
        }

        var messageBlocks: [[String: Any]] = try request.messages.map { message in
            [
                "role": message.role.rawValue,
                "content": try message.content.compactMap(contentBlock),
            ]
        }
        if var lastMessage = messageBlocks.popLast(),
           var content = lastMessage["content"] as? [[String: Any]],
           var lastBlock = content.popLast() {
            lastBlock["cache_control"] = ["type": "ephemeral"]
            content.append(lastBlock)
            lastMessage["content"] = content
            messageBlocks.append(lastMessage)
        }

        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": request.maxOutputTokens,
            "stream": true,
            "system": [[
                "type": "text",
                "text": request.system,
                "cache_control": ["type": "ephemeral"],
            ]],
            "messages": messageBlocks,
        ]
        if !toolBlocks.isEmpty { body["tools"] = toolBlocks }
        for (key, value) in request.additionalBody {
            body[key] = value.foundationValue
        }
        return body
    }

    private static func contentBlock(_ block: AgentInputBlock) throws -> [String: Any]? {
        switch block {
        case .text(let text):
            guard !text.isEmpty else { return nil }
            return ["type": "text", "text": text]

        case .image(let base64, let mimeType):
            return [
                "type": "image",
                "source": ["type": "base64", "media_type": mimeType, "data": base64],
            ]

        case .toolCall(let id, let name, let inputJSON):
            return [
                "type": "tool_use",
                "id": id,
                "name": name,
                "input": try AgentStreamSupport.jsonObject(from: inputJSON),
            ]

        case .toolResult(let toolCallID, let content, let isError):
            let resultContent: [[String: Any]] = content.map { block in
                switch block {
                case .text(let text):
                    ["type": "text", "text": text]
                case .image(let base64, let mimeType):
                    [
                        "type": "image",
                        "source": ["type": "base64", "media_type": mimeType, "data": base64],
                    ]
                }
            }
            return [
                "type": "tool_result",
                "tool_use_id": toolCallID,
                "content": resultContent,
                "is_error": isError,
            ]
        }
    }
}
