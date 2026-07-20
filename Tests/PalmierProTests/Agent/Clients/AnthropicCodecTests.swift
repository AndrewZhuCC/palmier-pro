import Foundation
import Testing
@testable import PalmierPro

@Suite("Anthropic Agent codec")
struct AnthropicCodecTests {
    @Test func requestBodyEncodesNeutralConversationAndCacheBoundaries() throws {
        let request = AgentRequest(
            model: "claude-test",
            maxOutputTokens: 4096,
            system: "System instructions",
            tools: [AgentToolDefinition(
                name: "inspect_timeline",
                description: "Inspect the edit",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ])
            )],
            messages: [
                AgentConversationMessage(role: .user, content: [
                    .text("Look at this"),
                    .image(base64: "aW1hZ2U=", mimeType: "image/png"),
                ]),
                AgentConversationMessage(role: .assistant, content: [
                    .toolCall(id: "call-1", name: "inspect_timeline", inputJSON: "{\"detail\":true}"),
                ]),
                AgentConversationMessage(role: .user, content: [
                    .toolResult(
                        toolCallID: "call-1",
                        content: [.text("done"), .image(base64: "cmVzdWx0", mimeType: "image/jpeg")],
                        isError: false
                    ),
                ]),
            ],
            additionalBody: ["temperature": .number(0.2)]
        )

        let body = try AnthropicRequestBody.build(request: request)
        #expect(body["model"] as? String == "claude-test")
        #expect(body["max_tokens"] as? Int == 4096)
        #expect(body["stream"] as? Bool == true)
        #expect(body["temperature"] as? Double == 0.2)

        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect((tools[0]["cache_control"] as? [String: String])?["type"] == "ephemeral")

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 3)
        let firstContent = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(firstContent[0]["type"] as? String == "text")
        #expect(firstContent[1]["type"] as? String == "image")
        let finalContent = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(finalContent[0]["type"] as? String == "tool_result")
        #expect((finalContent[0]["cache_control"] as? [String: String])?["type"] == "ephemeral")
    }

    @Test func streamDecoderAggregatesToolArgumentsAndFinishReason() throws {
        var decoder = AnthropicStreamDecoder()

        let usageEvents = try decoder.decode(event([
            "type": "message_start",
            "message": ["usage": [
                "input_tokens": 10,
                "output_tokens": 0,
                "cache_read_input_tokens": 4,
            ]],
        ]))
        #expect(usageEvents == [.usage(AgentUsage(
            inputTokens: 10,
            outputTokens: 0,
            cachedInputTokens: 4,
            cacheCreationInputTokens: nil
        ))])

        #expect(try decoder.decode(event([
            "type": "content_block_start",
            "index": 1,
            "content_block": ["type": "tool_use", "id": "call-1", "name": "inspect_timeline", "input": [:]],
        ])).isEmpty)
        #expect(try decoder.decode(event([
            "type": "content_block_delta",
            "index": 1,
            "delta": ["type": "input_json_delta", "partial_json": "{\"frame\":"],
        ])).isEmpty)
        #expect(try decoder.decode(event([
            "type": "content_block_delta",
            "index": 1,
            "delta": ["type": "input_json_delta", "partial_json": "42}"],
        ])).isEmpty)

        #expect(try decoder.decode(event([
            "type": "content_block_stop",
            "index": 1,
        ])) == [.toolCallComplete(
            id: "call-1",
            name: "inspect_timeline",
            inputJSON: "{\"frame\":42}"
        )])
        #expect(try decoder.decode(event([
            "type": "message_delta",
            "delta": ["stop_reason": "tool_use"],
        ])) == [.finish(.toolCalls)])
    }

    @Test func streamDecoderEmitsTextAndRejectsMalformedJSON() throws {
        var decoder = AnthropicStreamDecoder()
        #expect(try decoder.decode(event([
            "type": "content_block_delta",
            "index": 0,
            "delta": ["type": "text_delta", "text": "Hello"],
        ])) == [.textDelta("Hello")])

        #expect(throws: AIProviderError.invalidResponse("Anthropic stream event is not valid JSON.")) {
            try decoder.decode(SSEEvent(event: nil, id: nil, data: "not-json", retryMilliseconds: nil))
        }
    }

    private func event(_ object: [String: Any]) throws -> SSEEvent {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return SSEEvent(
            event: object["type"] as? String,
            id: nil,
            data: try #require(String(data: data, encoding: .utf8)),
            retryMilliseconds: nil
        )
    }
}
