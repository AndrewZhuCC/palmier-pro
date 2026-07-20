import Foundation
import Testing
@testable import PalmierPro

@Suite("AI provider core")
struct AIProviderCoreTests {
    @Test func resolvesEndpointBelowBasePath() throws {
        let url = try AIProviderEndpoint.resolve(
            baseURL: "https://gateway.example/v1/",
            endpointPath: "/chat/completions",
            allowInsecureHTTP: false
        )
        #expect(url.absoluteString == "https://gateway.example/v1/chat/completions")
    }

    @Test func allowsLoopbackHTTPWithoutOptIn() throws {
        let url = try AIProviderEndpoint.normalizedBaseURL(
            "http://127.0.0.1:11434/v1/",
            allowInsecureHTTP: false
        )
        #expect(url.absoluteString == "http://127.0.0.1:11434/v1")
    }

    @Test func rejectsRemoteHTTPWithoutOptIn() {
        #expect(throws: AIProviderConfigurationError.insecureHTTPRequiresConsent) {
            try AIProviderEndpoint.normalizedBaseURL(
                "http://gateway.example/v1",
                allowInsecureHTTP: false
            )
        }
    }

    @Test func rejectsReservedRequestBodyKeys() {
        let profile = AIProviderProfile(
            name: "Gateway",
            baseURL: "https://gateway.example/v1",
            auth: ProviderAuthConfiguration(kind: .bearer),
            agent: AgentEndpointConfiguration(
                wireProtocol: .openAIResponses,
                defaultModelID: "model",
                additionalBody: ["tools": .array([])]
            )
        )
        #expect(throws: AIProviderConfigurationError.reservedBodyKey("tools")) {
            try AIProviderEndpoint.validate(profile)
        }
    }

    @Test(arguments: [
        (AgentWireProtocol.openAIResponses, "Instructions"),
        (AgentWireProtocol.openAIResponses, "max_output_tokens"),
        (AgentWireProtocol.openAIChatCompletions, "Max_Tokens"),
        (AgentWireProtocol.openAIChatCompletions, "stream_options"),
        (AgentWireProtocol.anthropicMessages, "MAX_TOKENS"),
        (AgentWireProtocol.palmierManaged, "max_tokens"),
    ])
    func rejectsProtocolSpecificReservedBodyKeys(
        wireProtocol: AgentWireProtocol,
        reservedKey: String
    ) {
        let profile = AIProviderProfile(
            id: wireProtocol == .palmierManaged ? AIProviderProfile.palmierManagedID : UUID(),
            name: "Gateway",
            baseURL: wireProtocol == .palmierManaged ? "" : "https://gateway.example/v1",
            auth: ProviderAuthConfiguration(
                kind: wireProtocol == .palmierManaged ? .palmierManaged : .bearer
            ),
            agent: AgentEndpointConfiguration(
                wireProtocol: wireProtocol,
                defaultModelID: "model",
                additionalBody: [reservedKey: .bool(true)]
            )
        )
        #expect(throws: AIProviderConfigurationError.reservedBodyKey(reservedKey)) {
            try AIProviderEndpoint.validate(profile)
        }
    }

    @Test(arguments: [
        "../",
        "a/../../b",
        "%2e%2e",
        "%252e%252e",
        "chat\\completions",
        "a/%2e%2e/b",
        "seg/%2E",
    ])
    func rejectsUnsafeEndpointPaths(_ endpointPath: String) {
        let profile = AIProviderProfile(
            name: "Gateway",
            baseURL: "https://gateway.example/v1",
            auth: ProviderAuthConfiguration(kind: .bearer),
            agent: AgentEndpointConfiguration(
                wireProtocol: .openAIResponses,
                endpointPath: endpointPath,
                defaultModelID: "model"
            )
        )
        #expect(throws: AIProviderConfigurationError.invalidEndpointPath) {
            try AIProviderEndpoint.validate(profile)
        }
    }

    @Test func allowsEndpointPathsWithLeadingAndTrailingSlashes() throws {
        let profile = AIProviderProfile(
            name: "Gateway",
            baseURL: "https://gateway.example/v1",
            auth: ProviderAuthConfiguration(kind: .bearer),
            agent: AgentEndpointConfiguration(
                wireProtocol: .openAIResponses,
                endpointPath: "/responses/",
                defaultModelID: "model"
            )
        )
        try AIProviderEndpoint.validate(profile)
        let url = try AIProviderEndpoint.resolve(
            baseURL: "https://gateway.example/v1",
            endpointPath: "/responses/",
            allowInsecureHTTP: false
        )
        #expect(url.absoluteString == "https://gateway.example/v1/responses")
    }

    @Test func rejectsMixedPalmierAndBYOKProfileMarkers() {
        var profile = AIProviderProfile(
            name: "Invalid managed profile",
            baseURL: "https://gateway.example/v1",
            auth: ProviderAuthConfiguration(kind: .bearer),
            agent: AgentEndpointConfiguration(
                wireProtocol: .openAIResponses,
                defaultModelID: "model"
            )
        )
        profile.id = AIProviderProfile.palmierManagedID

        #expect(throws: AIProviderConfigurationError.invalidManagedProfile) {
            try AIProviderEndpoint.validate(profile)
        }
    }

    @Test func rejectsUnicodeHeaderNames() {
        let profile = AIProviderProfile(
            name: "Gateway",
            baseURL: "https://gateway.example/v1",
            auth: ProviderAuthConfiguration(kind: .bearer),
            headers: [ProviderHeaderConfiguration(name: "X-自定义", value: "ok")],
            agent: AgentEndpointConfiguration(
                wireProtocol: .openAIResponses,
                defaultModelID: "model"
            )
        )
        #expect(throws: AIProviderConfigurationError.invalidHeaderName("X-自定义")) {
            try AIProviderEndpoint.validate(profile)
        }
    }

    @Test func customHeaderAuthAllowsAuthorizationButRejectsHost() throws {
        let allowed = AIProviderProfile(
            name: "Gateway",
            baseURL: "https://gateway.example/v1",
            auth: ProviderAuthConfiguration(kind: .customHeader, headerName: "Authorization"),
            agent: AgentEndpointConfiguration(
                wireProtocol: .openAIResponses,
                defaultModelID: "model"
            )
        )
        try AIProviderEndpoint.validate(allowed)

        let rejected = AIProviderProfile(
            name: "Gateway",
            baseURL: "https://gateway.example/v1",
            auth: ProviderAuthConfiguration(kind: .customHeader, headerName: "Host"),
            agent: AgentEndpointConfiguration(
                wireProtocol: .openAIResponses,
                defaultModelID: "model"
            )
        )
        #expect(throws: AIProviderConfigurationError.protectedHeader("Host")) {
            try AIProviderEndpoint.validate(rejected)
        }
    }

    @Test func rejectsDuplicateCustomAuthHeader() {
        let profile = AIProviderProfile(
            name: "Gateway",
            baseURL: "https://gateway.example/v1",
            auth: ProviderAuthConfiguration(kind: .customHeader, headerName: "X-Gateway-Key"),
            headers: [ProviderHeaderConfiguration(name: "x-gateway-key", value: "duplicate")],
            agent: AgentEndpointConfiguration(
                wireProtocol: .openAIResponses,
                defaultModelID: "model"
            )
        )
        #expect(throws: AIProviderConfigurationError.duplicateHeader("x-gateway-key")) {
            try AIProviderEndpoint.validate(profile)
        }
    }

    @Test func rejectsCRLFInCredentialWithoutLeakingSecret() {
        let profile = AIProviderProfile(
            name: "Gateway",
            baseURL: "https://gateway.example/v1",
            auth: ProviderAuthConfiguration(kind: .bearer),
            agent: AgentEndpointConfiguration(
                wireProtocol: .openAIResponses,
                defaultModelID: "model"
            )
        )
        let secret = "sk-live-secret\r\ninjected"
        do {
            _ = try AIProviderRuntimeProfile.resolve(
                profile: profile,
                primaryCredential: secret,
                secretHeaderValues: [:]
            )
            Issue.record("Expected invalidHeaderValue for CRLF credential")
        } catch let error as AIProviderConfigurationError {
            #expect(error == .invalidHeaderValue("credential"))
            let description = String(describing: error)
            let localized = error.errorDescription ?? ""
            #expect(!description.contains("sk-live-secret"))
            #expect(!localized.contains("sk-live-secret"))
            #expect(!description.contains("\r"))
            #expect(!localized.contains("\r"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func rejectsCRLFInHeaderValueWithoutLeakingSecret() {
        let profile = AIProviderProfile(
            name: "Gateway",
            baseURL: "https://gateway.example/v1",
            auth: ProviderAuthConfiguration(kind: .bearer),
            headers: [
                ProviderHeaderConfiguration(name: "X-Trace", value: "good\r\nX-Injected: evil"),
            ],
            agent: AgentEndpointConfiguration(
                wireProtocol: .openAIResponses,
                defaultModelID: "model"
            )
        )
        do {
            try AIProviderEndpoint.validate(profile)
            Issue.record("Expected invalidHeaderValue for CRLF header value")
        } catch let error as AIProviderConfigurationError {
            #expect(error == .invalidHeaderValue("X-Trace"))
            let description = String(describing: error)
            let localized = error.errorDescription ?? ""
            #expect(!description.contains("X-Injected"))
            #expect(!localized.contains("X-Injected"))
            #expect(!description.contains("evil"))
            #expect(!localized.contains("evil"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func secretHeaderJSONDecodeScrubsAndReencodeOmitsSecret() throws {
        let json = """
        {
          "id": "11111111-1111-4111-8111-111111111111",
          "name": "X-Workspace-Key",
          "value": "workspace-secret-value",
          "isSecret": true
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ProviderHeaderConfiguration.self, from: json)
        #expect(decoded.isSecret)
        #expect(decoded.value == nil)
        #expect(decoded.name == "X-Workspace-Key")

        let encoded = try JSONEncoder().encode(decoded)
        let encodedObject = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(encodedObject["value"] == nil)
        let encodedText = String(data: encoded, encoding: .utf8) ?? ""
        #expect(!encodedText.contains("workspace-secret-value"))
    }

    @Test func rejectsProtectedExtraHeaders() {
        let profile = AIProviderProfile(
            name: "Gateway",
            baseURL: "https://gateway.example/v1",
            auth: ProviderAuthConfiguration(kind: .bearer),
            headers: [ProviderHeaderConfiguration(name: "Authorization", value: "other")],
            agent: AgentEndpointConfiguration(
                wireProtocol: .openAIResponses,
                defaultModelID: "model"
            )
        )
        #expect(throws: AIProviderConfigurationError.protectedHeader("Authorization")) {
            try AIProviderEndpoint.validate(profile)
        }
    }

    @Test func comparesOriginsUsingDefaultPorts() throws {
        let first = try #require(URL(string: "https://example.com/v1"))
        let second = try #require(URL(string: "https://example.com:443/other"))
        let third = try #require(URL(string: "https://other.example/other"))
        #expect(AIProviderEndpoint.sameOrigin(first, second))
        #expect(!AIProviderEndpoint.sameOrigin(first, third))
    }

    @Test func jsonValueRoundTrips() throws {
        let value: JSONValue = .object([
            "enabled": .bool(true),
            "nested": .array([.number(3), .null, .string("ok")]),
        ])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }

    @Test func repositoryRoundTripsSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-provider-repository-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = AIProviderRepository(fileURL: directory.appendingPathComponent("providers.json"))
        var profile = AIProviderProfile.anthropic(apiModel: "claude-test")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        profile.createdAt = timestamp
        profile.updatedAt = timestamp
        let expected = AIProviderConfigurationSnapshot(
            profiles: [profile],
            activeAgentProfileID: profile.id
        )

        try await repository.save(expected)
        #expect(try await repository.load() == expected)
    }
}

@Suite("SSE parser")
struct SSEParserTests {
    @Test func parsesNamedMultilineEvent() {
        var parser = SSEParser()
        #expect(parser.consume(line: ": keepalive") == nil)
        #expect(parser.consume(line: "event: response.output_text.delta") == nil)
        #expect(parser.consume(line: "id: evt-1") == nil)
        #expect(parser.consume(line: "data: {\"delta\":") == nil)
        #expect(parser.consume(line: "data: \"hello\"}") == nil)
        let event = parser.consume(line: "")

        #expect(event == SSEEvent(
            event: "response.output_text.delta",
            id: "evt-1",
            data: "{\"delta\":\n\"hello\"}",
            retryMilliseconds: nil
        ))
    }

    @Test func finishDispatchesFinalEventWithoutBlankLine() {
        var parser = SSEParser()
        _ = parser.consume(line: "data: [DONE]")
        #expect(parser.finish()?.data == "[DONE]")
    }
}

@Suite("AI provider store")
@MainActor
struct AIProviderStoreTests {
    @Test func rejectsDuplicateProfileIdentifiersOnLoad() async throws {
        let suiteName = "AIProviderStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = AIProviderProfile.anthropic(apiModel: "claude-one")
        var duplicate = AIProviderProfile.anthropic(apiModel: "claude-two")
        duplicate.id = first.id
        let repository = MemoryProviderRepository(snapshot: AIProviderConfigurationSnapshot(
            profiles: [first, duplicate]
        ))
        let store = AIProviderStore(
            repository: repository,
            credentials: MemoryCredentialStore(),
            userDefaults: defaults
        )

        await store.loadNow()

        #expect(store.profiles.isEmpty)
        #expect(store.lastError == AIProviderStoreError.duplicateProfileID.errorDescription)
    }

    @Test func migratesLegacyAnthropicCredentialTransactionally() async throws {
        let suiteName = "AIProviderStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("claude-migrated", forKey: "agentModel")

        let managed = AIProviderProfile.palmierManaged(
            baseURL: URL(string: "https://palmier.example")!
        )
        let repository = MemoryProviderRepository(snapshot: AIProviderConfigurationSnapshot(
            profiles: [managed],
            activeAgentProfileID: managed.id
        ))
        let credentials = MemoryCredentialStore(legacyAnthropic: "sk-ant-legacy")
        let store = AIProviderStore(
            repository: repository,
            credentials: credentials,
            userDefaults: defaults
        )

        await store.loadNow()

        let profile = try #require(store.activeAgentProfile)
        #expect(profile.agent?.wireProtocol == .anthropicMessages)
        #expect(profile.agent?.defaultModelID == "claude-migrated")
        #expect(store.hasCredential(for: profile))
        let migratedCredential = await credentials.primaryCredential(for: profile.id)
        let legacyCredential = await credentials.legacyAnthropicCredential()
        let savedSnapshot = await repository.currentSnapshot()
        #expect(migratedCredential == "sk-ant-legacy")
        #expect(legacyCredential == nil)
        #expect(savedSnapshot.activeAgentProfileID == profile.id)
        #expect(savedSnapshot.profiles.contains(where: { $0.id == managed.id }))
        #expect(profile.id.uuidString == "00000000-0000-4000-8000-000000000002")
    }

    @Test func migrationRollsBackNewCredentialWhenMetadataSaveFails() async throws {
        let suiteName = "AIProviderStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let managed = AIProviderProfile.palmierManaged(
            baseURL: URL(string: "https://palmier.example")!
        )
        let repository = FailingSaveProviderRepository(snapshot: AIProviderConfigurationSnapshot(
            profiles: [managed],
            activeAgentProfileID: managed.id
        ))
        let credentials = MemoryCredentialStore(legacyAnthropic: "sk-ant-legacy")
        let store = AIProviderStore(
            repository: repository,
            credentials: credentials,
            userDefaults: defaults
        )

        await store.loadNow()

        #expect(store.lastError != nil)
        #expect(await credentials.primaryValueCount() == 0)
        #expect(await credentials.legacyAnthropicCredential() == "sk-ant-legacy")
    }

    @Test func saveProfileRollsBackCredentialWhenMetadataSaveFails() async throws {
        let suiteName = "AIProviderStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = FailingSaveProviderRepository(
            snapshot: AIProviderConfigurationSnapshot()
        )
        let credentials = MemoryCredentialStore()
        let store = AIProviderStore(
            repository: repository,
            credentials: credentials,
            userDefaults: defaults
        )
        let profile = AIProviderProfile.anthropic(apiModel: "claude-test")

        do {
            try await store.saveProfile(profile, primaryCredential: "replacement-secret")
            Issue.record("Expected metadata save to fail")
        } catch {
            // Expected.
        }

        #expect(await credentials.primaryValueCount() == 0)
    }

    @Test func secretHeadersParticipateInCredentialReadiness() async throws {
        let secretHeader = ProviderHeaderConfiguration(name: "X-Workspace-Key", isSecret: true)
        let profile = AIProviderProfile(
            name: "Gateway",
            baseURL: "https://gateway.example/v1",
            auth: ProviderAuthConfiguration(kind: .none),
            headers: [secretHeader],
            generation: GenerationEndpointConfiguration(providerKind: .compatibleV1)
        )
        let repository = MemoryProviderRepository(snapshot: AIProviderConfigurationSnapshot(
            profiles: [profile]
        ))
        let credentials = MemoryCredentialStore()
        let suiteName = "AIProviderStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AIProviderStore(
            repository: repository,
            credentials: credentials,
            userDefaults: defaults
        )

        await store.loadNow()
        #expect(!store.hasCredential(for: profile))

        await credentials.setSecretHeaderValue(
            "workspace-secret",
            profileID: profile.id,
            headerID: secretHeader.id
        )
        await store.loadNow()
        #expect(store.hasCredential(for: profile))
    }

    @Test func resolvesPrimaryAndSecretHeadersAtRuntimeOnly() async throws {
        let secretHeader = ProviderHeaderConfiguration(name: "X-Workspace-Key", isSecret: true)
        let profile = AIProviderProfile(
            name: "Gateway",
            baseURL: "https://gateway.example/v1",
            auth: ProviderAuthConfiguration(kind: .bearer),
            headers: [
                ProviderHeaderConfiguration(name: "X-Region", value: "us-east"),
                secretHeader,
            ],
            agent: AgentEndpointConfiguration(
                wireProtocol: .openAIResponses,
                defaultModelID: "model"
            )
        )
        let repository = MemoryProviderRepository(snapshot: AIProviderConfigurationSnapshot(
            profiles: [profile],
            activeAgentProfileID: profile.id
        ))
        let credentials = MemoryCredentialStore()
        await credentials.setPrimaryCredential("primary-secret", for: profile.id)
        await credentials.setSecretHeaderValue(
            "workspace-secret",
            profileID: profile.id,
            headerID: secretHeader.id
        )
        let defaults = try #require(UserDefaults(suiteName: "AIProviderStoreTests.\(UUID().uuidString)"))
        let store = AIProviderStore(
            repository: repository,
            credentials: credentials,
            userDefaults: defaults
        )

        await store.loadNow()
        let runtime = try await store.activeAgentRuntimeProfile()

        #expect(runtime.headers["Authorization"] == "Bearer primary-secret")
        #expect(runtime.headers["X-Region"] == "us-east")
        #expect(runtime.headers["X-Workspace-Key"] == "workspace-secret")
        #expect(runtime.profile.headers.first(where: { $0.id == secretHeader.id })?.value == nil)
    }
}

actor MemoryProviderRepository: AIProviderConfigurationPersisting {
    private var snapshot: AIProviderConfigurationSnapshot

    init(snapshot: AIProviderConfigurationSnapshot = AIProviderConfigurationSnapshot()) {
        self.snapshot = snapshot
    }

    func load() -> AIProviderConfigurationSnapshot { snapshot }

    func save(_ snapshot: AIProviderConfigurationSnapshot) {
        self.snapshot = snapshot
    }

    func currentSnapshot() -> AIProviderConfigurationSnapshot { snapshot }
}

actor FailingSaveProviderRepository: AIProviderConfigurationPersisting {
    private let snapshot: AIProviderConfigurationSnapshot

    init(snapshot: AIProviderConfigurationSnapshot) {
        self.snapshot = snapshot
    }

    func load() -> AIProviderConfigurationSnapshot { snapshot }

    func save(_ snapshot: AIProviderConfigurationSnapshot) throws {
        _ = snapshot
        throw CocoaError(.fileWriteUnknown)
    }
}

actor MemoryCredentialStore: AIProviderCredentialStoring {
    private var primaryValues: [UUID: String] = [:]
    private var headerValues: [String: String] = [:]
    private var legacyValue: String?

    init(legacyAnthropic: String? = nil) {
        legacyValue = legacyAnthropic
    }

    func primaryCredential(for profileID: UUID) -> String? {
        primaryValues[profileID]
    }

    func setPrimaryCredential(_ value: String?, for profileID: UUID) {
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            primaryValues[profileID] = value
        } else {
            primaryValues.removeValue(forKey: profileID)
        }
    }

    func secretHeaderValue(profileID: UUID, headerID: UUID) -> String? {
        headerValues[key(profileID: profileID, headerID: headerID)]
    }

    func setSecretHeaderValue(_ value: String?, profileID: UUID, headerID: UUID) {
        let storageKey = key(profileID: profileID, headerID: headerID)
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            headerValues[storageKey] = value
        } else {
            headerValues.removeValue(forKey: storageKey)
        }
    }

    func removeCredentials(profileID: UUID, headerIDs: [UUID]) {
        primaryValues.removeValue(forKey: profileID)
        for headerID in headerIDs {
            headerValues.removeValue(forKey: key(profileID: profileID, headerID: headerID))
        }
    }

    func legacyAnthropicCredential() -> String? { legacyValue }

    func primaryValueCount() -> Int { primaryValues.count }

    func removeLegacyAnthropicCredential() {
        legacyValue = nil
    }

    private func key(profileID: UUID, headerID: UUID) -> String {
        "\(profileID.uuidString):\(headerID.uuidString)"
    }
}
