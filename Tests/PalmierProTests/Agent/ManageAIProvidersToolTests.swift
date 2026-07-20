import Foundation
import MCP
import Testing
@testable import PalmierPro

@Suite("manage_ai_providers", .serialized)
@MainActor
struct ManageAIProvidersToolTests {
    @Test func toolIsMCPOnlyAndSchemaHasNoCredentialField() throws {
        let mcpTool = try #require(ToolDefinitions.mcpServer.first { $0.name == .manageAIProviders })
        #expect(!ToolDefinitions.inAppAgent.contains { $0.name == .manageAIProviders })
        let schema = try #require(ToolExecutor.jsonString(mcpTool.inputSchema))
        #expect(!schema.localizedCaseInsensitiveContains("apiKey"))
        #expect(!schema.localizedCaseInsensitiveContains("secretValue"))
        #expect(schema.contains("set_credentials"))
        #expect(mcpTool.description.contains("Never ask the user to paste API keys"))
    }

    @Test func createsConfiguresTestsAndDeletesWithoutAProject() async throws {
        let fixture = try ProviderToolFixture()
        defer { fixture.cleanup() }
        await fixture.store.loadNow()
        let secret = "sentinel-provider-secret"
        let executor = ToolExecutor(
            projectProvider: { nil },
            providerStore: fixture.store,
            providerCredentialPrompter: FixedCredentialPrompter(
                secret: secret,
                expectedBaseURL: "https://queue.fal.run"
            )
        )

        let created = await executor.execute(name: "manage_ai_providers", args: [
            "action": "create",
            "preset": "fal-queue",
            "configuration": ["name": "Video Provider"],
        ], source: "mcp")
        #expect(!created.isError)
        let createdJSON = try toolJSON(created)
        let providerID = try #require(createdJSON["providerId"] as? String)
        #expect(createdJSON["credentialStatus"] as? String == "missing")
        #expect(!toolText(created).contains(secret))

        let configured = await executor.execute(name: "manage_ai_providers", args: [
            "action": "set_credentials",
            "providerId": providerID,
            "operation": "prompt_missing",
        ], source: "mcp")
        #expect(!configured.isError)
        #expect(try toolJSON(configured)["credentialStatus"] as? String == "ready")
        #expect(!toolText(configured).contains(secret))

        let profileUUID = try #require(UUID(uuidString: providerID))
        #expect(await fixture.credentials.primaryCredential(for: profileUUID) == secret)
        let persisted = try JSONEncoder().encode(await fixture.repository.currentSnapshot())
        #expect(!String(decoding: persisted, as: UTF8.self).contains(secret))

        let tested = await executor.execute(name: "manage_ai_providers", args: [
            "action": "test",
            "providerId": providerID,
        ], source: "mcp")
        #expect(!tested.isError)
        let testedJSON = try toolJSON(tested)
        let checks = try #require(testedJSON["checks"] as? [[String: Any]])
        #expect(checks.first?["networkTestPerformed"] as? Bool == false)

        let listed = await executor.execute(name: "manage_ai_providers", args: [
            "action": "list",
        ], source: "mcp")
        #expect(!listed.isError)
        #expect(!toolText(listed).contains(secret))

        let removed = await executor.execute(name: "manage_ai_providers", args: [
            "action": "set_credentials",
            "providerId": providerID,
            "operation": "remove",
        ], source: "mcp")
        #expect(!removed.isError)
        #expect(try toolJSON(removed)["credentialStatus"] as? String == "missing")
        #expect(await fixture.credentials.primaryCredential(for: profileUUID) == nil)

        let replaced = await executor.execute(name: "manage_ai_providers", args: [
            "action": "set_credentials",
            "providerId": providerID,
            "operation": "replace",
        ], source: "mcp")
        #expect(!replaced.isError)
        #expect(try toolJSON(replaced)["credentialStatus"] as? String == "ready")
        #expect(await fixture.credentials.primaryCredential(for: profileUUID) == secret)

        let unconfirmedDelete = await executor.execute(name: "manage_ai_providers", args: [
            "action": "delete",
            "providerId": providerID,
        ], source: "mcp")
        #expect(unconfirmedDelete.isError)
        #expect(fixture.store.profile(id: profileUUID) != nil)

        let deleted = await executor.execute(name: "manage_ai_providers", args: [
            "action": "delete",
            "providerId": providerID,
            "confirm": true,
        ], source: "mcp")
        #expect(!deleted.isError)
        #expect(fixture.store.profile(id: profileUUID) == nil)
        #expect(await fixture.credentials.primaryCredential(for: profileUUID) == nil)
    }

    @Test func updatesReuseSecretHeaderIdsAndSupportExplicitServiceRemoval() async throws {
        let fixture = try ProviderToolFixture()
        defer { fixture.cleanup() }
        await fixture.store.loadNow()
        let executor = ToolExecutor(projectProvider: { nil }, providerStore: fixture.store)
        let localModel: [String: Any] = [
            "id": "video-model",
            "kind": "video",
            "display_name": "Video Model",
            "capabilities": ["durations": [5], "aspect_ratios": ["16:9"]],
        ]

        let created = await executor.execute(name: "manage_ai_providers", args: [
            "action": "create",
            "configuration": [
                "name": "Gateway",
                "baseURL": "https://gateway.example/v1",
                "auth": ["kind": "none"],
                "headers": [["name": "X-Workspace-Key", "isSecret": true]],
                "agent": [
                    "protocol": "openai-responses",
                    "defaultModelId": "agent-model",
                ],
                "generation": [
                    "kind": "palmier-compatible-v1",
                    "options": ["models": [localModel]],
                ],
            ],
        ], source: "mcp")
        #expect(!created.isError)
        let createdJSON = try toolJSON(created)
        let providerID = try #require(createdJSON["providerId"] as? String)
        let createdHeaders = try #require(createdJSON["headers"] as? [[String: Any]])
        let secretHeaderID = try #require(createdHeaders.first?["id"] as? String)

        let updated = await executor.execute(name: "manage_ai_providers", args: [
            "action": "update",
            "providerId": providerID,
            "configuration": [
                "headers": [
                    ["name": "X-Workspace-Key", "isSecret": true],
                    ["name": "X-Region", "value": "us-east", "isSecret": false],
                ],
                "generation": NSNull(),
            ],
        ], source: "mcp")
        #expect(!updated.isError)
        let updatedJSON = try toolJSON(updated)
        let updatedHeaders = try #require(updatedJSON["headers"] as? [[String: Any]])
        #expect(updatedHeaders.first?["id"] as? String == secretHeaderID)
        #expect(updatedJSON["generation"] == nil)
        #expect(updatedJSON["agent"] != nil)

        let secretInline = await executor.execute(name: "manage_ai_providers", args: [
            "action": "update",
            "providerId": providerID,
            "configuration": [
                "headers": [[
                    "id": secretHeaderID,
                    "name": "X-Workspace-Key",
                    "value": "must-not-pass",
                    "isSecret": true,
                ]],
            ],
        ], source: "mcp")
        #expect(secretInline.isError)
        #expect(!toolText(secretInline).contains("must-not-pass"))
    }

    @Test func unsupportedAndCancelledCredentialPromptsDoNotMutateVault() async throws {
        let fixture = try ProviderToolFixture()
        defer { fixture.cleanup() }
        await fixture.store.loadNow()
        let executor = ToolExecutor(projectProvider: { nil }, providerStore: fixture.store)
        let created = await executor.execute(name: "manage_ai_providers", args: [
            "action": "create",
            "preset": "anthropic-messages",
        ], source: "mcp")
        let providerID = try #require(try toolJSON(created)["providerId"] as? String)
        let profileUUID = try #require(UUID(uuidString: providerID))

        let unavailable = await executor.execute(name: "manage_ai_providers", args: [
            "action": "set_credentials",
            "providerId": providerID,
            "operation": "prompt_missing",
        ], source: "mcp")
        #expect(unavailable.isError)
        #expect(await fixture.credentials.primaryCredential(for: profileUUID) == nil)

        executor.setProviderCredentialPrompter(CancelCredentialPrompter())
        let cancelled = await executor.execute(name: "manage_ai_providers", args: [
            "action": "set_credentials",
            "providerId": providerID,
            "operation": "replace",
        ], source: "mcp")
        #expect(!cancelled.isError)
        #expect(try toolJSON(cancelled)["status"] as? String == "cancelled")
        #expect(await fixture.credentials.primaryCredential(for: profileUUID) == nil)
    }

    @Test func managedProfilesAreProtected() async throws {
        let managed = AIProviderProfile.palmierManaged(baseURL: URL(string: "https://palmier.example")!)
        let fixture = try ProviderToolFixture(snapshot: AIProviderConfigurationSnapshot(
            profiles: [managed],
            activeAgentProfileID: managed.id
        ))
        defer { fixture.cleanup() }
        await fixture.store.loadNow()
        let executor = ToolExecutor(projectProvider: { nil }, providerStore: fixture.store)
        let providerID = managed.id.uuidString

        let updated = await executor.execute(name: "manage_ai_providers", args: [
            "action": "update",
            "providerId": providerID,
            "configuration": ["name": "Changed"],
        ], source: "mcp")
        #expect(updated.isError)

        let deleted = await executor.execute(name: "manage_ai_providers", args: [
            "action": "delete",
            "providerId": providerID,
            "confirm": true,
        ], source: "mcp")
        #expect(deleted.isError)
        #expect(fixture.store.profile(id: managed.id) != nil)
    }

    @Test func inMemoryMCPUsesInjectedSecurePromptAndKeepsSecretsOutOfResults() async throws {
        let fixture = try ProviderToolFixture()
        defer { fixture.cleanup() }
        await fixture.store.loadNow()
        let executor = ToolExecutor(projectProvider: { nil }, providerStore: fixture.store)
        let server = Server(
            name: "provider-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        let secret = "mcp-prompt-sentinel"
        await MCPService.registerTools(
            on: server,
            executor: executor,
            providerCredentialPrompter: FixedCredentialPrompter(
                secret: secret,
                expectedBaseURL: "https://api.anthropic.com/v1"
            )
        )
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "provider-client", version: "1.0.0")

        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            #expect(tools.contains { $0.name == "manage_ai_providers" })

            let created = try await client.callTool(name: "manage_ai_providers", arguments: [
                "action": .string("create"),
                "preset": .string("anthropic-messages"),
            ])
            let createdText = try mcpText(created.content)
            let createdJSON = try parseJSON(createdText)
            let providerID = try #require(createdJSON["providerId"] as? String)

            let configured = try await client.callTool(name: "manage_ai_providers", arguments: [
                "action": .string("set_credentials"),
                "providerId": .string(providerID),
                "operation": .string("prompt_missing"),
            ])
            #expect(configured.isError != true)
            let configuredText = try mcpText(configured.content)
            #expect(!configuredText.contains(secret))
            let profileUUID = try #require(UUID(uuidString: providerID))
            #expect(await fixture.credentials.primaryCredential(for: profileUUID) == secret)

            let listed = try await client.callTool(name: "manage_ai_providers", arguments: [
                "action": .string("list"),
            ])
            let listedText = try mcpText(listed.content)
            #expect(!listedText.contains(secret))
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    private func toolText(_ result: ToolResult) -> String {
        for block in result.content {
            if case .text(let text) = block { return text }
        }
        return ""
    }

    private func toolJSON(_ result: ToolResult) throws -> [String: Any] {
        try parseJSON(toolText(result))
    }

    private func mcpText(_ content: [Tool.Content]) throws -> String {
        for item in content {
            if case .text(let text, _, _) = item { return text }
        }
        throw CocoaError(.coderReadCorrupt)
    }

    private func parseJSON(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}

private struct FixedCredentialPrompter: AIProviderCredentialPrompting {
    let secret: String
    let expectedBaseURL: String

    func requestCredentials(
        _ request: AIProviderCredentialPromptRequest
    ) async throws -> AIProviderCredentialPromptOutcome {
        guard request.providerBaseURL == expectedBaseURL else {
            throw AIProviderCredentialPromptError.invalidResponse
        }
        return .accepted(Dictionary(uniqueKeysWithValues: request.fields.map { ($0.target, secret) }))
    }
}

private struct CancelCredentialPrompter: AIProviderCredentialPrompting {
    func requestCredentials(
        _ request: AIProviderCredentialPromptRequest
    ) async throws -> AIProviderCredentialPromptOutcome {
        _ = request
        return .cancelled
    }
}

@MainActor
private struct ProviderToolFixture {
    let suiteName: String
    let defaults: UserDefaults
    let repository: MemoryProviderRepository
    let credentials: MemoryCredentialStore
    let store: AIProviderStore

    init(snapshot: AIProviderConfigurationSnapshot = AIProviderConfigurationSnapshot()) throws {
        suiteName = "ManageAIProvidersToolTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        repository = MemoryProviderRepository(snapshot: snapshot)
        credentials = MemoryCredentialStore()
        store = AIProviderStore(
            repository: repository,
            credentials: credentials,
            userDefaults: defaults
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
