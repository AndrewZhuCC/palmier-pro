import Foundation

enum AgentWireProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAIResponses = "openai-responses"
    case openAIChatCompletions = "openai-chat-completions"
    case anthropicMessages = "anthropic-messages"
    case palmierManaged = "palmier-managed"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openAIResponses: "OpenAI Responses"
        case .openAIChatCompletions: "OpenAI Chat Completions"
        case .anthropicMessages: "Anthropic Messages"
        case .palmierManaged: "Palmier Cloud"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAIResponses, .openAIChatCompletions:
            "https://api.openai.com/v1"
        case .anthropicMessages:
            "https://api.anthropic.com/v1"
        case .palmierManaged:
            ""
        }
    }

    var defaultEndpointPath: String {
        switch self {
        case .openAIResponses: "responses"
        case .openAIChatCompletions: "chat/completions"
        case .anthropicMessages: "messages"
        case .palmierManaged: "v1/agent/stream"
        }
    }
}

enum GenerationProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case palmierManaged = "palmier-managed"
    case falQueue = "fal-queue"
    case openAIMedia = "openai-media"
    case compatibleV1 = "palmier-compatible-v1"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .palmierManaged: "Palmier Cloud"
        case .falQueue: "fal.ai"
        case .openAIMedia: "OpenAI Media"
        case .compatibleV1: "Compatible Provider v1"
        }
    }
}

enum ProviderAuthKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case bearer
    case xAPIKey = "x-api-key"
    case customHeader = "custom-header"
    case none
    case palmierManaged = "palmier-managed"

    var id: String { rawValue }
}

struct ProviderAuthConfiguration: Codable, Sendable, Equatable {
    var kind: ProviderAuthKind
    var headerName: String?
    var valuePrefix: String?

    init(kind: ProviderAuthKind, headerName: String? = nil, valuePrefix: String? = nil) {
        self.kind = kind
        self.headerName = headerName
        self.valuePrefix = valuePrefix
    }
}

struct ProviderHeaderConfiguration: Identifiable, Sendable, Equatable {
    var id: UUID
    var name: String
    var value: String?
    var isSecret: Bool

    init(id: UUID = UUID(), name: String, value: String? = nil, isSecret: Bool = false) {
        self.id = id
        self.name = name
        self.value = isSecret ? nil : value
        self.isSecret = isSecret
    }
}

extension ProviderHeaderConfiguration: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, value, isSecret
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        isSecret = try container.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
        let decodedValue = try container.decodeIfPresent(String.self, forKey: .value)
        // Secret headers never retain values in provider metadata.
        value = isSecret ? nil : decodedValue
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isSecret, forKey: .isSecret)
        if !isSecret {
            try container.encodeIfPresent(value, forKey: .value)
        }
    }
}

struct AgentModelOption: Codable, Identifiable, Sendable, Equatable {
    var modelID: String
    var displayName: String

    var id: String { modelID }

    init(modelID: String, displayName: String? = nil) {
        self.modelID = modelID
        self.displayName = displayName ?? modelID
    }
}

struct AgentEndpointConfiguration: Codable, Sendable, Equatable {
    var wireProtocol: AgentWireProtocol
    var endpointPath: String
    var defaultModelID: String
    var models: [AgentModelOption]
    var maxOutputTokens: Int
    var additionalBody: [String: JSONValue]

    init(
        wireProtocol: AgentWireProtocol,
        endpointPath: String? = nil,
        defaultModelID: String,
        models: [AgentModelOption] = [],
        maxOutputTokens: Int = 16_384,
        additionalBody: [String: JSONValue] = [:]
    ) {
        self.wireProtocol = wireProtocol
        self.endpointPath = endpointPath ?? wireProtocol.defaultEndpointPath
        self.defaultModelID = defaultModelID
        self.models = models.isEmpty ? [AgentModelOption(modelID: defaultModelID)] : models
        self.maxOutputTokens = maxOutputTokens
        self.additionalBody = additionalBody
    }
}

struct GenerationEndpointConfiguration: Codable, Sendable, Equatable {
    var providerKind: GenerationProviderKind
    var endpointPath: String?
    var modelIDs: [String]
    var options: [String: JSONValue]

    init(
        providerKind: GenerationProviderKind,
        endpointPath: String? = nil,
        modelIDs: [String] = [],
        options: [String: JSONValue] = [:]
    ) {
        self.providerKind = providerKind
        self.endpointPath = endpointPath
        self.modelIDs = modelIDs
        self.options = options
    }
}

struct AIProviderProfile: Codable, Identifiable, Sendable, Equatable {
    static let palmierManagedID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

    var id: UUID
    var name: String
    var baseURL: String
    var enabled: Bool
    var allowInsecureHTTP: Bool
    var allowCredentialRedirects: Bool
    var auth: ProviderAuthConfiguration
    var headers: [ProviderHeaderConfiguration]
    var agent: AgentEndpointConfiguration?
    var generation: GenerationEndpointConfiguration?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        enabled: Bool = true,
        allowInsecureHTTP: Bool = false,
        allowCredentialRedirects: Bool = false,
        auth: ProviderAuthConfiguration,
        headers: [ProviderHeaderConfiguration] = [],
        agent: AgentEndpointConfiguration? = nil,
        generation: GenerationEndpointConfiguration? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.enabled = enabled
        self.allowInsecureHTTP = allowInsecureHTTP
        self.allowCredentialRedirects = allowCredentialRedirects
        self.auth = auth
        self.headers = headers
        self.agent = agent
        self.generation = generation
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL, enabled, allowInsecureHTTP, allowCredentialRedirects
        case auth, headers, agent, generation, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        allowInsecureHTTP = try container.decodeIfPresent(Bool.self, forKey: .allowInsecureHTTP) ?? false
        allowCredentialRedirects = try container.decodeIfPresent(
            Bool.self,
            forKey: .allowCredentialRedirects
        ) ?? false
        auth = try container.decodeIfPresent(
            ProviderAuthConfiguration.self,
            forKey: .auth
        ) ?? ProviderAuthConfiguration(kind: .none)
        headers = try container.decodeIfPresent(
            [ProviderHeaderConfiguration].self,
            forKey: .headers
        ) ?? []
        agent = try container.decodeIfPresent(AgentEndpointConfiguration.self, forKey: .agent)
        generation = try container.decodeIfPresent(
            GenerationEndpointConfiguration.self,
            forKey: .generation
        )
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    var isManagedPalmier: Bool {
        id == Self.palmierManagedID && auth.kind == .palmierManaged
    }

    var requiresPrimaryCredential: Bool {
        switch auth.kind {
        case .bearer, .xAPIKey, .customHeader: true
        case .none, .palmierManaged: false
        }
    }
}

struct AIProviderConfigurationSnapshot: Codable, Sendable, Equatable {
    static let currentVersion = 1

    var version: Int
    var profiles: [AIProviderProfile]
    var activeAgentProfileID: UUID?

    init(
        version: Int = currentVersion,
        profiles: [AIProviderProfile] = [],
        activeAgentProfileID: UUID? = nil
    ) {
        self.version = version
        self.profiles = profiles
        self.activeAgentProfileID = activeAgentProfileID
    }

    private enum CodingKeys: String, CodingKey {
        case version, profiles, activeAgentProfileID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        profiles = try container.decodeIfPresent([AIProviderProfile].self, forKey: .profiles) ?? []
        activeAgentProfileID = try container.decodeIfPresent(UUID.self, forKey: .activeAgentProfileID)
    }
}

struct AIProviderRuntimeProfile: Sendable {
    let profile: AIProviderProfile
    let primaryCredential: String?
    let headers: [String: String]
}

extension AIProviderProfile {
    static func anthropic(apiModel: String) -> AIProviderProfile {
        AIProviderProfile(
            name: "Anthropic",
            baseURL: AgentWireProtocol.anthropicMessages.defaultBaseURL,
            auth: ProviderAuthConfiguration(kind: .xAPIKey),
            agent: AgentEndpointConfiguration(
                wireProtocol: .anthropicMessages,
                defaultModelID: apiModel,
                additionalBody: apiModel == "claude-sonnet-5"
                    ? ["output_config": .object(["effort": .string("low")])]
                    : [:]
            )
        )
    }

    static func palmierManaged(baseURL: URL) -> AIProviderProfile {
        AIProviderProfile(
            id: palmierManagedID,
            name: "Palmier Cloud",
            baseURL: baseURL.absoluteString,
            auth: ProviderAuthConfiguration(kind: .palmierManaged),
            agent: AgentEndpointConfiguration(
                wireProtocol: .palmierManaged,
                defaultModelID: "claude-sonnet-5",
                additionalBody: ["output_config": .object(["effort": .string("low")])]
            ),
            generation: GenerationEndpointConfiguration(providerKind: .palmierManaged)
        )
    }
}
