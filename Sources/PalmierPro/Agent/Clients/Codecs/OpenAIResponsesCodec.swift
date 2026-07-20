import Foundation

struct OpenAIResponsesStreamDecoder: Sendable {
    private struct PendingCall: Sendable {
        var callID: String
        var name: String
        var arguments: String
    }

    private var pendingByKey: [String: PendingCall] = [:]
    private var emittedCallIDs: Set<String> = []
    private var producedFunctionCall = false

    mutating func decode(_ serverEvent: SSEEvent) throws -> [AgentStreamEvent] {
        guard let data = serverEvent.data.data(using: .utf8) else {
            throw AIProviderError.invalidResponse("OpenAI Responses stream event is not valid JSON.")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AIProviderError.invalidResponse("OpenAI Responses stream event is not valid JSON.")
        }
        guard let event = object as? [String: Any],
              let type = event["type"] as? String else {
            throw AIProviderError.invalidResponse("OpenAI Responses stream event is not valid JSON.")
        }

        switch type {
        case "response.output_text.delta":
            guard let delta = event["delta"] as? String, !delta.isEmpty else { return [] }
            return [.textDelta(delta)]

        case "response.output_item.added":
            guard let item = event["item"] as? [String: Any],
                  item["type"] as? String == "function_call" else { return [] }
            let callID = (item["call_id"] as? String) ?? ""
            let name = (item["name"] as? String) ?? ""
            let arguments = (item["arguments"] as? String) ?? ""
            let pending = PendingCall(callID: callID, name: name, arguments: arguments)
            for key in Self.lookupKeys(event: event, item: item) {
                pendingByKey[key] = pending
            }
            return []

        case "response.function_call_arguments.delta":
            guard let delta = event["delta"] as? String, !delta.isEmpty,
                  let match = findPending(event: event, item: nil) else { return [] }
            var pending = match.pending
            pending.arguments += delta
            write(pending, keys: match.keys)
            return []

        case "response.output_item.done":
            guard let item = event["item"] as? [String: Any],
                  item["type"] as? String == "function_call" else { return [] }
            let match = findPending(event: event, item: item)
            let keys = match?.keys ?? Self.lookupKeys(event: event, item: item)
            let existing = match?.pending
            let callID = (item["call_id"] as? String) ?? existing?.callID ?? ""
            if !callID.isEmpty, emittedCallIDs.contains(callID) {
                removePending(keys: keys)
                return []
            }
            let name = (item["name"] as? String) ?? existing?.name ?? ""
            guard !callID.isEmpty, !name.isEmpty else {
                throw AIProviderError.invalidResponse("OpenAI Responses function call is missing its id or name.")
            }
            let doneArguments = item["arguments"] as? String
            let accumulated = existing?.arguments ?? ""
            let arguments: String
            if let doneArguments, !doneArguments.isEmpty {
                arguments = doneArguments
            } else if !accumulated.isEmpty {
                arguments = accumulated
            } else {
                arguments = "{}"
            }
            removePending(keys: keys)
            if !callID.isEmpty {
                emittedCallIDs.insert(callID)
            }
            producedFunctionCall = true
            return [.toolCallComplete(id: callID, name: name, inputJSON: arguments)]

        case "response.completed":
            var events: [AgentStreamEvent] = []
            if let usage = parseUsage(from: event) {
                AgentUsageLog.record(usage)
                events.append(.usage(usage))
            }
            events.append(.finish(producedFunctionCall ? .toolCalls : .completed))
            return events

        case "response.incomplete":
            var events: [AgentStreamEvent] = []
            if let usage = parseUsage(from: event) {
                AgentUsageLog.record(usage)
                events.append(.usage(usage))
            }
            let reason = ((event["response"] as? [String: Any])?["incomplete_details"] as? [String: Any])?["reason"] as? String
            let finish: AgentFinishReason
            if reason == "max_output_tokens" {
                finish = .maxOutputTokens
            } else {
                finish = .other(reason)
            }
            events.append(.finish(finish))
            return events

        case "response.failed", "error":
            throw AIProviderError.streamError(Self.errorCode(from: event))

        default:
            return []
        }
    }

    private mutating func write(_ pending: PendingCall, keys: [String]) {
        for key in keys {
            pendingByKey[key] = pending
        }
    }

    private mutating func removePending(keys: [String]) {
        for key in keys {
            pendingByKey.removeValue(forKey: key)
        }
    }

    private func findPending(
        event: [String: Any],
        item: [String: Any]?
    ) -> (keys: [String], pending: PendingCall)? {
        let candidates = Self.lookupKeys(event: event, item: item)
        guard let foundKey = candidates.first(where: { pendingByKey[$0] != nil }),
              let pending = pendingByKey[foundKey] else { return nil }
        var keys = candidates
        for (key, value) in pendingByKey where value.callID == pending.callID && !keys.contains(key) {
            keys.append(key)
        }
        if !keys.contains(foundKey) {
            keys.append(foundKey)
        }
        return (keys, pending)
    }

    private static func lookupKeys(event: [String: Any], item: [String: Any]?) -> [String] {
        var keys: [String] = []
        if let index = intValue(event["output_index"]) {
            keys.append("idx:\(index)")
        }
        if let itemID = event["item_id"] as? String {
            keys.append("id:\(itemID)")
        } else if let itemID = item?["id"] as? String {
            keys.append("id:\(itemID)")
        }
        return keys
    }

    private static func intValue(_ raw: Any?) -> Int? {
        switch raw {
        case let value as Int: value
        case let value as NSNumber: value.intValue
        default: nil
        }
    }

    private func parseUsage(from event: [String: Any]) -> AgentUsage? {
        let usage = (event["response"] as? [String: Any])?["usage"] as? [String: Any]
            ?? event["usage"] as? [String: Any]
        guard let usage else { return nil }
        let details = usage["input_tokens_details"] as? [String: Any]
        return AgentUsage(
            inputTokens: Self.intValue(usage["input_tokens"]),
            outputTokens: Self.intValue(usage["output_tokens"]),
            cachedInputTokens: Self.intValue(details?["cached_tokens"]),
            cacheCreationInputTokens: nil
        )
    }

    private static func errorCode(from event: [String: Any]) -> String {
        if let error = event["error"] as? [String: Any] {
            if let code = error["code"] as? String, !code.isEmpty { return code }
            if let type = error["type"] as? String, !type.isEmpty { return type }
        }
        if let response = event["response"] as? [String: Any],
           let error = response["error"] as? [String: Any] {
            if let code = error["code"] as? String, !code.isEmpty { return code }
            if let type = error["type"] as? String, !type.isEmpty { return type }
        }
        if let code = event["code"] as? String, !code.isEmpty { return code }
        return event["type"] as? String ?? "provider_error"
    }
}

enum OpenAIResponsesRequestBody {
    static func build(request: AgentRequest) throws -> [String: Any] {
        var body: [String: Any] = [
            "model": request.model,
            "stream": true,
            "store": false,
            "max_output_tokens": request.maxOutputTokens,
            "instructions": request.system,
            "input": try encodeInput(messages: request.messages),
        ]
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                [
                    "type": "function",
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.inputSchema.foundationValue,
                ] as [String: Any]
            }
        }
        for (key, value) in request.additionalBody {
            body[key] = value.foundationValue
        }
        return body
    }

    private static func encodeInput(messages: [AgentConversationMessage]) throws -> [[String: Any]] {
        var items: [[String: Any]] = []
        for message in messages {
            var contentParts: [[String: Any]] = []

            func flushMessage() {
                guard !contentParts.isEmpty else { return }
                items.append([
                    "role": message.role.rawValue,
                    "content": contentParts,
                ])
                contentParts.removeAll(keepingCapacity: true)
            }

            for block in message.content {
                switch block {
                case .text(let text):
                    guard !text.isEmpty else { continue }
                    contentParts.append([
                        "type": "input_text",
                        "text": text,
                    ])

                case .image(let base64, let mimeType):
                    if message.role == .assistant {
                        throw AIProviderError.unsupportedContent(
                            "OpenAI Responses does not support assistant image content."
                        )
                    }
                    contentParts.append([
                        "type": "input_image",
                        "image_url": "data:\(mimeType);base64,\(base64)",
                    ])

                case .toolCall(let id, let name, let inputJSON):
                    flushMessage()
                    items.append([
                        "type": "function_call",
                        "call_id": id,
                        "name": name,
                        "arguments": inputJSON,
                    ])

                case .toolResult(let toolCallID, let content, let isError):
                    flushMessage()
                    items.append([
                        "type": "function_call_output",
                        "call_id": toolCallID,
                        "output": encodeToolResultOutput(content: content, isError: isError),
                    ])
                }
            }
            flushMessage()
        }
        return items
    }

    private static func encodeToolResultOutput(
        content: [AgentToolResultBlock],
        isError: Bool
    ) -> Any {
        let hasImage = content.contains { block in
            if case .image = block { return true }
            return false
        }

        if hasImage {
            var parts: [[String: Any]] = []
            var appliedErrorPrefix = false
            for block in content {
                switch block {
                case .text(let text):
                    let value: String
                    if isError && !appliedErrorPrefix {
                        value = "Tool error: \(text)"
                        appliedErrorPrefix = true
                    } else {
                        value = text
                    }
                    parts.append([
                        "type": "input_text",
                        "text": value,
                    ])
                case .image(let base64, let mimeType):
                    parts.append([
                        "type": "input_image",
                        "image_url": "data:\(mimeType);base64,\(base64)",
                    ])
                }
            }
            if isError && !appliedErrorPrefix {
                parts.insert([
                    "type": "input_text",
                    "text": "Tool error: ",
                ], at: 0)
            }
            return parts
        }

        var texts: [String] = []
        for block in content {
            if case .text(let text) = block {
                texts.append(text)
            }
        }
        if isError {
            if texts.isEmpty {
                return "Tool error: "
            }
            texts[0] = "Tool error: \(texts[0])"
        }
        return texts.joined(separator: "\n")
    }
}
