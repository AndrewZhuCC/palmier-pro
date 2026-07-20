import Foundation
import Testing
@testable import PalmierPro

@Suite("OpenAI Responses codec")
struct OpenAIResponsesCodecTests {
    @Test func requestBodyEncodesSystemModelStoreAndToolSchema() throws {
        let request = AgentRequest(
            model: "gpt-test-model",
            maxOutputTokens: 2048,
            system: "You are a test agent.",
            tools: [
                AgentToolDefinition(
                    name: "lookup_clip",
                    description: "Find a clip",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "clipId": .object(["type": .string("string")]),
                        ]),
                    ])
                ),
            ],
            messages: [
                AgentConversationMessage(role: .user, content: [.text("hello")]),
            ],
            additionalBody: ["temperature": .number(0)]
        )

        let body = try OpenAIResponsesRequestBody.build(request: request)
        #expect(body["model"] as? String == "gpt-test-model")
        #expect(body["stream"] as? Bool == true)
        #expect(body["store"] as? Bool == false)
        #expect(body["max_output_tokens"] as? Int == 2048)
        #expect(body["instructions"] as? String == "You are a test agent.")
        #expect(body["temperature"] as? Double == 0)

        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "function")
        #expect(tools[0]["name"] as? String == "lookup_clip")
        #expect(tools[0]["description"] as? String == "Find a clip")
        let parameters = try #require(tools[0]["parameters"] as? [String: Any])
        #expect(parameters["type"] as? String == "object")
    }

    @Test func requestBodyPreservesMessageAndToolOrder() throws {
        let request = AgentRequest(
            model: "gpt-test-model",
            maxOutputTokens: 1024,
            system: "sys",
            tools: [],
            messages: [
                AgentConversationMessage(
                    role: .user,
                    content: [
                        .text("describe"),
                        .image(base64: "ZmFrZQ==", mimeType: "image/png"),
                    ]
                ),
                AgentConversationMessage(
                    role: .assistant,
                    content: [
                        .text("ok"),
                        .toolCall(id: "call_fake_1", name: "lookup_clip", inputJSON: #"{"clipId":"ABCD1234"}"#),
                    ]
                ),
                AgentConversationMessage(
                    role: .user,
                    content: [
                        .toolResult(
                            toolCallID: "call_fake_1",
                            content: [
                                .text("found"),
                                .image(base64: "aW1n", mimeType: "image/jpeg"),
                            ],
                            isError: false
                        ),
                    ]
                ),
            ],
            additionalBody: [:]
        )

        let body = try OpenAIResponsesRequestBody.build(request: request)
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.count == 4)

        #expect(input[0]["role"] as? String == "user")
        let userContent = try #require(input[0]["content"] as? [[String: Any]])
        #expect(userContent.count == 2)
        #expect(userContent[0]["type"] as? String == "input_text")
        #expect(userContent[0]["text"] as? String == "describe")
        #expect(userContent[1]["type"] as? String == "input_image")
        #expect(userContent[1]["image_url"] as? String == "data:image/png;base64,ZmFrZQ==")

        #expect(input[1]["role"] as? String == "assistant")
        let assistantContent = try #require(input[1]["content"] as? [[String: Any]])
        #expect(assistantContent.count == 1)
        #expect(assistantContent[0]["type"] as? String == "input_text")
        #expect(assistantContent[0]["text"] as? String == "ok")

        #expect(input[2]["type"] as? String == "function_call")
        #expect(input[2]["call_id"] as? String == "call_fake_1")
        #expect(input[2]["name"] as? String == "lookup_clip")
        #expect(input[2]["arguments"] as? String == #"{"clipId":"ABCD1234"}"#)

        #expect(input[3]["type"] as? String == "function_call_output")
        #expect(input[3]["call_id"] as? String == "call_fake_1")
        let output = try #require(input[3]["output"] as? [[String: Any]])
        #expect(output.count == 2)
        #expect(output[0]["type"] as? String == "input_text")
        #expect(output[0]["text"] as? String == "found")
        #expect(output[1]["type"] as? String == "input_image")
        #expect(output[1]["image_url"] as? String == "data:image/jpeg;base64,aW1n")
    }

    @Test func requestBodyRejectsAssistantImage() {
        let request = AgentRequest(
            model: "gpt-test-model",
            maxOutputTokens: 128,
            system: "sys",
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
            "OpenAI Responses does not support assistant image content."
        )) {
            try OpenAIResponsesRequestBody.build(request: request)
        }
    }

    @Test func requestBodyPrefixesToolErrorText() throws {
        let request = AgentRequest(
            model: "gpt-test-model",
            maxOutputTokens: 128,
            system: "sys",
            tools: [],
            messages: [
                AgentConversationMessage(
                    role: .user,
                    content: [
                        .toolResult(
                            toolCallID: "call_err",
                            content: [.text("boom")],
                            isError: true
                        ),
                    ]
                ),
            ],
            additionalBody: [:]
        )
        let body = try OpenAIResponsesRequestBody.build(request: request)
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input[0]["output"] as? String == "Tool error: boom")
    }

    @Test func streamDecoderEmitsTextDelta() throws {
        var decoder = OpenAIResponsesStreamDecoder()
        let events = try decoder.decode(sseEvent([
            "type": "response.output_text.delta",
            "delta": "Hello",
        ]))
        #expect(events == [.textDelta("Hello")])
    }

    @Test func streamDecoderAggregatesFunctionArgumentsOnce() throws {
        var decoder = OpenAIResponsesStreamDecoder()

        #expect(try decoder.decode(sseEvent([
            "type": "response.output_item.added",
            "output_index": 0,
            "item": [
                "id": "fc_fake_1",
                "type": "function_call",
                "call_id": "call_fake_1",
                "name": "lookup_clip",
                "arguments": "",
            ],
        ])).isEmpty)

        #expect(try decoder.decode(sseEvent([
            "type": "response.function_call_arguments.delta",
            "output_index": 0,
            "item_id": "fc_fake_1",
            "delta": #"{"clipId":"#,
        ])).isEmpty)

        #expect(try decoder.decode(sseEvent([
            "type": "response.function_call_arguments.delta",
            "output_index": 0,
            "item_id": "fc_fake_1",
            "delta": #"ABCD"}"#,
        ])).isEmpty)

        let done = try decoder.decode(sseEvent([
            "type": "response.output_item.done",
            "output_index": 0,
            "item": [
                "id": "fc_fake_1",
                "type": "function_call",
                "call_id": "call_fake_1",
                "name": "lookup_clip",
                "arguments": #"{"clipId":"ABCD"}"#,
            ],
        ]))
        #expect(done == [
            .toolCallComplete(
                id: "call_fake_1",
                name: "lookup_clip",
                inputJSON: #"{"clipId":"ABCD"}"#
            ),
        ])

        let duplicate = try decoder.decode(sseEvent([
            "type": "response.output_item.done",
            "output_index": 0,
            "item": [
                "id": "fc_fake_1",
                "type": "function_call",
                "call_id": "call_fake_1",
                "name": "lookup_clip",
                "arguments": #"{"clipId":"ABCD"}"#,
            ],
        ]))
        #expect(duplicate.isEmpty)
    }

    @Test func streamDecoderCompletedEmitsUsageAndToolCallsFinish() throws {
        var decoder = OpenAIResponsesStreamDecoder()
        _ = try decoder.decode(sseEvent([
            "type": "response.output_item.added",
            "output_index": 1,
            "item": [
                "id": "fc_fake_2",
                "type": "function_call",
                "call_id": "call_fake_2",
                "name": "lookup_clip",
                "arguments": "",
            ],
        ]))
        _ = try decoder.decode(sseEvent([
            "type": "response.output_item.done",
            "output_index": 1,
            "item": [
                "id": "fc_fake_2",
                "type": "function_call",
                "call_id": "call_fake_2",
                "name": "lookup_clip",
                "arguments": #"{"clipId":"ZZ"}"#,
            ],
        ]))

        let events = try decoder.decode(sseEvent([
            "type": "response.completed",
            "response": [
                "usage": [
                    "input_tokens": 11,
                    "output_tokens": 7,
                    "input_tokens_details": [
                        "cached_tokens": 3,
                    ],
                ],
            ],
        ]))
        #expect(events == [
            .usage(AgentUsage(
                inputTokens: 11,
                outputTokens: 7,
                cachedInputTokens: 3,
                cacheCreationInputTokens: nil
            )),
            .finish(.toolCalls),
        ])
    }

    @Test func streamDecoderIncompleteMapsMaxOutputTokens() throws {
        var decoder = OpenAIResponsesStreamDecoder()
        let events = try decoder.decode(sseEvent([
            "type": "response.incomplete",
            "response": [
                "incomplete_details": ["reason": "max_output_tokens"],
                "usage": [
                    "input_tokens": 5,
                    "output_tokens": 9,
                    "input_tokens_details": ["cached_tokens": 0],
                ],
            ],
        ]))
        #expect(events == [
            .usage(AgentUsage(
                inputTokens: 5,
                outputTokens: 9,
                cachedInputTokens: 0,
                cacheCreationInputTokens: nil
            )),
            .finish(.maxOutputTokens),
        ])
    }

    @Test func streamDecoderRejectsMalformedAndFailedEvents() throws {
        var decoder = OpenAIResponsesStreamDecoder()
        #expect(throws: AIProviderError.invalidResponse(
            "OpenAI Responses stream event is not valid JSON."
        )) {
            try decoder.decode(SSEEvent(event: nil, id: nil, data: "{not-json", retryMilliseconds: nil))
        }

        #expect(throws: AIProviderError.streamError("server_error")) {
            try decoder.decode(sseEvent([
                "type": "response.failed",
                "response": [
                    "error": [
                        "code": "server_error",
                        "message": "should-not-leak-secret-body",
                    ],
                ],
            ]))
        }

        #expect(throws: AIProviderError.streamError("invalid_request")) {
            try decoder.decode(sseEvent([
                "type": "error",
                "error": [
                    "type": "invalid_request",
                    "message": "do-not-include",
                ],
            ]))
        }
    }

    private func sseEvent(_ object: [String: Any]) -> SSEEvent {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return SSEEvent(
            event: object["type"] as? String,
            id: nil,
            data: String(data: data, encoding: .utf8)!,
            retryMilliseconds: nil
        )
    }
}
