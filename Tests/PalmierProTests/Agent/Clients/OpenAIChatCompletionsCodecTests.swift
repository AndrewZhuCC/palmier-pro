import Foundation
import Testing
@testable import PalmierPro

@Suite("OpenAI Chat Completions codec")
struct OpenAIChatCompletionsCodecTests {
    @Test func buildsRequestBodyWithSystemModelMaxTokensAndToolSchema() throws {
        let request = AgentRequest(
            model: "gpt-test-model",
            maxOutputTokens: 2_048,
            system: "You are a test assistant.",
            tools: [
                AgentToolDefinition(
                    name: "lookup_clip",
                    description: "Look up a clip by id.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "clip_id": .object(["type": .string("string")]),
                        ]),
                        "required": .array([.string("clip_id")]),
                    ])
                ),
            ],
            messages: [
                AgentConversationMessage(role: .user, content: [.text("Find clip A")]),
            ],
            additionalBody: ["temperature": .number(0)]
        )

        let body = try OpenAIChatCompletionsRequestBody.build(request: request)

        #expect(body["model"] as? String == "gpt-test-model")
        #expect(body["stream"] as? Bool == true)
        #expect(body["max_tokens"] as? Int == 2_048)
        #expect(body["temperature"] as? Double == 0)

        let streamOptions = try #require(body["stream_options"] as? [String: Any])
        #expect(streamOptions["include_usage"] as? Bool == true)

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "You are a test assistant.")
        #expect(messages[1]["role"] as? String == "user")

        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "function")
        let function = try #require(tools[0]["function"] as? [String: Any])
        #expect(function["name"] as? String == "lookup_clip")
        #expect(function["description"] as? String == "Look up a clip by id.")
        let parameters = try #require(function["parameters"] as? [String: Any])
        #expect(parameters["type"] as? String == "object")
        let properties = try #require(parameters["properties"] as? [String: Any])
        #expect(properties["clip_id"] != nil)
    }

    @Test func preservesUserImageAssistantToolCallsAndToolResultOrder() throws {
        let request = AgentRequest(
            model: "gpt-test-model",
            maxOutputTokens: 1_024,
            system: "system",
            tools: [],
            messages: [
                AgentConversationMessage(
                    role: .user,
                    content: [
                        .text("before image"),
                        .image(base64: "ZmFrZS1pbWFnZS1ieXRlcw==", mimeType: "image/png"),
                        .text("after image"),
                    ]
                ),
                AgentConversationMessage(
                    role: .assistant,
                    content: [
                        .text("I will call tools."),
                        .toolCall(id: "call_a", name: "tool_a", inputJSON: #"{"x":1}"#),
                        .toolCall(id: "call_b", name: "tool_b", inputJSON: #"{"y":2}"#),
                    ]
                ),
                AgentConversationMessage(
                    role: .user,
                    content: [
                        .text("pre result"),
                        .toolResult(toolCallID: "call_a", content: [.text("result-a")], isError: false),
                        .toolResult(toolCallID: "call_b", content: [.text("result-b")], isError: false),
                        .text("post result"),
                    ]
                ),
            ],
            additionalBody: [:]
        )

        let body = try OpenAIChatCompletionsRequestBody.build(request: request)
        let messages = try #require(body["messages"] as? [[String: Any]])

        #expect(messages[0]["role"] as? String == "system")

        #expect(messages[1]["role"] as? String == "user")
        let userContent = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(userContent.count == 3)
        #expect(userContent[0]["type"] as? String == "text")
        #expect(userContent[0]["text"] as? String == "before image")
        #expect(userContent[1]["type"] as? String == "image_url")
        let imageURL = try #require((userContent[1]["image_url"] as? [String: Any])?["url"] as? String)
        #expect(imageURL == "data:image/png;base64,ZmFrZS1pbWFnZS1ieXRlcw==")
        #expect(userContent[2]["text"] as? String == "after image")

        #expect(messages[2]["role"] as? String == "assistant")
        let assistantContent = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(assistantContent.count == 1)
        #expect(assistantContent[0]["text"] as? String == "I will call tools.")
        let toolCalls = try #require(messages[2]["tool_calls"] as? [[String: Any]])
        #expect(toolCalls.count == 2)
        #expect(toolCalls[0]["id"] as? String == "call_a")
        #expect((toolCalls[0]["function"] as? [String: Any])?["name"] as? String == "tool_a")
        #expect((toolCalls[0]["function"] as? [String: Any])?["arguments"] as? String == #"{"x":1}"#)
        #expect(toolCalls[1]["id"] as? String == "call_b")
        #expect((toolCalls[1]["function"] as? [String: Any])?["name"] as? String == "tool_b")

        #expect(messages[3]["role"] as? String == "user")
        let preResult = try #require(messages[3]["content"] as? [[String: Any]])
        #expect(preResult.count == 1)
        #expect(preResult[0]["text"] as? String == "pre result")

        #expect(messages[4]["role"] as? String == "tool")
        #expect(messages[4]["tool_call_id"] as? String == "call_a")
        #expect(messages[4]["content"] as? String == "result-a")

        #expect(messages[5]["role"] as? String == "tool")
        #expect(messages[5]["tool_call_id"] as? String == "call_b")
        #expect(messages[5]["content"] as? String == "result-b")

        #expect(messages[6]["role"] as? String == "user")
        let postResult = try #require(messages[6]["content"] as? [[String: Any]])
        #expect(postResult.count == 1)
        #expect(postResult[0]["text"] as? String == "post result")
    }

    @Test func rejectsAssistantImageAndToolResultImage() {
        let assistantImage = AgentRequest(
            model: "gpt-test-model",
            maxOutputTokens: 128,
            system: "system",
            tools: [],
            messages: [
                AgentConversationMessage(
                    role: .assistant,
                    content: [.image(base64: "ZmFrZQ==", mimeType: "image/png")]
                ),
            ],
            additionalBody: [:]
        )
        #expect(throws: AIProviderError.unsupportedContent(
            "OpenAI Chat Completions does not support assistant image content."
        )) {
            try OpenAIChatCompletionsRequestBody.build(request: assistantImage)
        }

        let toolImage = AgentRequest(
            model: "gpt-test-model",
            maxOutputTokens: 128,
            system: "system",
            tools: [],
            messages: [
                AgentConversationMessage(
                    role: .user,
                    content: [
                        .toolResult(
                            toolCallID: "call_img",
                            content: [.image(base64: "ZmFrZQ==", mimeType: "image/jpeg")],
                            isError: false
                        ),
                    ]
                ),
            ],
            additionalBody: [:]
        )
        #expect(throws: AIProviderError.unsupportedContent(
            "OpenAI Chat Completions does not support image tool results."
        )) {
            try OpenAIChatCompletionsRequestBody.build(request: toolImage)
        }
    }

    @Test func decodesTextDelta() throws {
        var decoder = OpenAIChatCompletionsStreamDecoder()
        let events = try decoder.decode(sseEvent(#"""
        {"id":"chatcmpl-test","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}
        """#))
        #expect(events == [.textDelta("Hello")])
    }

    @Test func aggregatesFragmentedParallelToolCallsAcrossChunks() throws {
        var decoder = OpenAIChatCompletionsStreamDecoder()

        let first = try decoder.decode(sseEvent(#"""
        {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_","type":"function","function":{"name":"tool_","arguments":"{\"a\":"}},{"index":1,"id":"call_","type":"function","function":{"name":"tool_","arguments":"{\"b\":"}}]},"finish_reason":null}]}
        """#))
        #expect(first.isEmpty)

        let second = try decoder.decode(sseEvent(#"""
        {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"one","function":{"name":"alpha","arguments":"1}"}},{"index":1,"id":"two","function":{"name":"beta","arguments":"2}"}}]},"finish_reason":null}]}
        """#))
        #expect(second.isEmpty)

        let finished = try decoder.decode(sseEvent(#"""
        {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}
        """#))
        #expect(finished == [
            .toolCallComplete(id: "call_one", name: "tool_alpha", inputJSON: #"{"a":1}"#),
            .toolCallComplete(id: "call_two", name: "tool_beta", inputJSON: #"{"b":2}"#),
            .finish(.toolCalls),
        ])
    }

    @Test func emitsToolCompleteBeforeFinishAndDoesNotRepeat() throws {
        var decoder = OpenAIChatCompletionsStreamDecoder()

        _ = try decoder.decode(sseEvent(#"""
        {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_x","type":"function","function":{"name":"do_thing","arguments":""}}]},"finish_reason":null}]}
        """#))

        let finished = try decoder.decode(sseEvent(#"""
        {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}
        """#))
        #expect(finished == [
            .toolCallComplete(id: "call_x", name: "do_thing", inputJSON: "{}"),
            .finish(.toolCalls),
        ])

        let repeated = try decoder.decode(sseEvent(#"""
        {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}
        """#))
        #expect(repeated == [.finish(.toolCalls)])
    }

    @Test func decodesUsageOnlyChunk() throws {
        var decoder = OpenAIChatCompletionsStreamDecoder()
        let events = try decoder.decode(sseEvent(#"""
        {"id":"chatcmpl-usage","choices":[],"usage":{"input_tokens":11,"output_tokens":7,"prompt_tokens_details":{"cached_tokens":3}}}
        """#))
        #expect(events == [
            .usage(AgentUsage(
                inputTokens: 11,
                outputTokens: 7,
                cachedInputTokens: 3,
                cacheCreationInputTokens: nil
            )),
        ])
    }

    @Test func handlesDoneMalformedJSONAndErrorEnvelope() throws {
        var decoder = OpenAIChatCompletionsStreamDecoder()

        let done = try decoder.decode(SSEEvent(event: nil, id: nil, data: "[DONE]", retryMilliseconds: nil))
        #expect(done.isEmpty)

        #expect(throws: AIProviderError.invalidResponse(
            "OpenAI Chat Completions stream event is not valid JSON."
        )) {
            var malformed = OpenAIChatCompletionsStreamDecoder()
            _ = try malformed.decode(SSEEvent(event: nil, id: nil, data: "{not-json", retryMilliseconds: nil))
        }

        #expect(throws: AIProviderError.streamError("server_error")) {
            var errorDecoder = OpenAIChatCompletionsStreamDecoder()
            _ = try errorDecoder.decode(sseEvent(#"""
            {"error":{"type":"server_error","code":"upstream_timeout","message":"secret provider details"}}
            """#))
        }
    }

    @Test func assistantToolCallsOnlyUsesNullContent() throws {
        let request = AgentRequest(
            model: "gpt-test-model",
            maxOutputTokens: 64,
            system: "system",
            tools: [],
            messages: [
                AgentConversationMessage(
                    role: .assistant,
                    content: [
                        .toolCall(id: "call_only", name: "solo", inputJSON: "{}"),
                    ]
                ),
            ],
            additionalBody: [:]
        )
        let body = try OpenAIChatCompletionsRequestBody.build(request: request)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let assistant = try #require(messages.last)
        #expect(assistant["role"] as? String == "assistant")
        #expect(assistant["content"] is NSNull)
        let toolCalls = try #require(assistant["tool_calls"] as? [[String: Any]])
        #expect(toolCalls.count == 1)
        #expect(toolCalls[0]["id"] as? String == "call_only")
    }

    private func sseEvent(_ data: String) -> SSEEvent {
        SSEEvent(event: nil, id: nil, data: data, retryMilliseconds: nil)
    }
}
