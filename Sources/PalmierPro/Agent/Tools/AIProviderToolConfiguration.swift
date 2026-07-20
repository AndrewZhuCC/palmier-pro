import Foundation

enum AIProviderToolCodec {
    static let presetIdentifiers = [
        "openai-responses",
        "openai-chat-completions",
        "anthropic-messages",
        "fal-queue",
        "openai-media",
        "compatible-generation",
    ]

    static var presetSummaries: [[String: Any]] {
        AIProviderPreset.allCases.map { preset in
            [
                "id": toolIdentifier(for: preset),
                "name": preset.label,
            ]
        }
    }

    static func makeProfileForCreate(
        presetIdentifier: String?,
        configuration rawConfiguration: Any?
    ) throws -> AIProviderProfile {
        var profile: AIProviderProfile
        if let presetIdentifier {
            guard let preset = preset(for: presetIdentifier) else {
                throw ToolError("manage_ai_providers.preset: unknown preset '\(presetIdentifier)'")
            }
            profile = preset.makeProfile()
        } else {
            profile = AIProviderProfile(
                name: "",
                baseURL: "",
                auth: ProviderAuthConfiguration(kind: .none)
            )
        }

        if let rawConfiguration {
            profile = try applyingProfilePatch(
                rawConfiguration,
                to: profile,
                path: "manage_ai_providers.configuration"
            )
        } else if presetIdentifier == nil {
            throw ToolError("manage_ai_providers: create requires 'preset' or 'configuration'")
        }

        let now = Date()
        profile.id = UUID()
        profile.createdAt = now
        profile.updatedAt = now
        applyDefaultBaseURLIfNeeded(to: &profile)
        try AIProviderEndpoint.validate(profile)
        return profile
    }

    static func updateProfile(
        _ existing: AIProviderProfile,
        configuration rawConfiguration: Any?
    ) throws -> AIProviderProfile {
        guard let rawConfiguration else {
            throw ToolError("manage_ai_providers: update requires 'configuration'")
        }
        var profile = try applyingProfilePatch(
            rawConfiguration,
            to: existing,
            path: "manage_ai_providers.configuration"
        )
        profile.id = existing.id
        profile.createdAt = existing.createdAt
        profile.updatedAt = Date()
        applyDefaultBaseURLIfNeeded(to: &profile)
        try AIProviderEndpoint.validate(profile)
        return profile
    }

    static func summary(
        profile: AIProviderProfile,
        credentialState: AIProviderCredentialState,
        activeAgentProfileID: UUID?
    ) -> [String: Any] {
        var auth: [String: Any] = ["kind": profile.auth.kind.rawValue]
        if let headerName = profile.auth.headerName { auth["headerName"] = headerName }
        if let valuePrefix = profile.auth.valuePrefix { auth["valuePrefix"] = valuePrefix }

        let headers: [[String: Any]] = profile.headers.map { header in
            var result: [String: Any] = [
                "id": header.id.uuidString.lowercased(),
                "name": header.name,
                "isSecret": header.isSecret,
            ]
            if !header.isSecret, let value = header.value {
                result["value"] = value
            }
            return result
        }

        var result: [String: Any] = [
            "providerId": profile.id.uuidString.lowercased(),
            "name": profile.name,
            "baseURL": profile.baseURL,
            "enabled": profile.enabled,
            "managed": profile.isManagedPalmier,
            "activeForAgent": activeAgentProfileID == profile.id,
            "allowInsecureHTTP": profile.allowInsecureHTTP,
            "allowCredentialRedirects": profile.allowCredentialRedirects,
            "auth": auth,
            "headers": headers,
            "credentialStatus": credentialState.statusIdentifier,
            "missingCredentials": allCredentialTargets(for: profile)
                .filter { !credentialState.isPresent($0) }
                .map(\.toolIdentifier),
        ]

        if let agent = profile.agent {
            result["agent"] = [
                "protocol": agent.wireProtocol.rawValue,
                "endpointPath": agent.endpointPath,
                "defaultModelId": agent.defaultModelID,
                "models": agent.models.map { model in
                    ["id": model.modelID, "displayName": model.displayName]
                },
                "maxOutputTokens": agent.maxOutputTokens,
                "additionalBody": agent.additionalBody.mapValues(\.foundationValue),
            ] as [String: Any]
        }

        if let generation = profile.generation {
            var value: [String: Any] = [
                "kind": generation.providerKind.rawValue,
                "modelIds": generation.modelIDs,
                "options": generation.options.mapValues(\.foundationValue),
            ]
            if let endpointPath = generation.endpointPath {
                value["endpointPath"] = endpointPath
            }
            result["generation"] = value
        }
        return result
    }

    static func selectedCredentialTargets(
        for profile: AIProviderProfile,
        state: AIProviderCredentialState,
        operation: String,
        requestedIdentifiers: [String]
    ) throws -> [AIProviderCredentialTarget] {
        let available = allCredentialTargets(for: profile)
        let selected: [AIProviderCredentialTarget]
        if requestedIdentifiers.isEmpty {
            selected = available
        } else {
            var seen = Set<AIProviderCredentialTarget>()
            selected = try requestedIdentifiers.map { identifier in
                guard let target = AIProviderCredentialTarget.parse(toolIdentifier: identifier),
                      available.contains(target) else {
                    throw ToolError("manage_ai_providers.targets: unknown credential target '\(identifier)'")
                }
                guard seen.insert(target).inserted else {
                    throw ToolError("manage_ai_providers.targets: duplicate target '\(identifier)'")
                }
                return target
            }
        }

        if operation == "prompt_missing" {
            return selected.filter { !state.isPresent($0) }
        }
        return selected
    }

    static func promptFields(
        for targets: [AIProviderCredentialTarget],
        profile: AIProviderProfile
    ) throws -> [AIProviderCredentialPromptField] {
        try targets.map { target in
            switch target {
            case .primary:
                guard profile.requiresPrimaryCredential else {
                    throw ToolError("manage_ai_providers.targets: provider does not use a primary credential")
                }
                return AIProviderCredentialPromptField(
                    target: target,
                    label: "API key",
                    validationName: "credential"
                )
            case .secretHeader(let id):
                guard let header = profile.headers.first(where: { $0.id == id && $0.isSecret }) else {
                    throw ToolError("manage_ai_providers.targets: secret header not found")
                }
                return AIProviderCredentialPromptField(
                    target: target,
                    label: header.name,
                    validationName: header.name
                )
            }
        }
    }

    static func credentialValues(
        _ values: [AIProviderCredentialTarget: String]
    ) -> (primary: String?, headers: [UUID: String]) {
        var primary: String?
        var headers: [UUID: String] = [:]
        for (target, value) in values {
            switch target {
            case .primary:
                primary = value
            case .secretHeader(let id):
                headers[id] = value
            }
        }
        return (primary, headers)
    }

    static func removalValues(
        for targets: [AIProviderCredentialTarget]
    ) -> (primary: String?, headers: [UUID: String]) {
        var primary: String?
        var headers: [UUID: String] = [:]
        for target in targets {
            switch target {
            case .primary:
                primary = ""
            case .secretHeader(let id):
                headers[id] = ""
            }
        }
        return (primary, headers)
    }

    private static func applyingProfilePatch(
        _ rawValue: Any,
        to original: AIProviderProfile,
        path: String
    ) throws -> AIProviderProfile {
        guard let patch = rawValue as? [String: Any] else {
            throw ToolError("\(path): expected object")
        }
        try validateUnknownKeys(
            patch,
            allowed: [
                "name", "baseURL", "enabled", "allowInsecureHTTP",
                "allowCredentialRedirects", "auth", "headers", "agent", "generation",
            ],
            path: path
        )

        var profile = original
        if patch.keys.contains("name") {
            profile.name = try requiredString(patch["name"], path: "\(path).name")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if patch.keys.contains("baseURL") {
            profile.baseURL = try requiredString(patch["baseURL"], path: "\(path).baseURL")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if patch.keys.contains("enabled") {
            profile.enabled = try requiredBool(patch["enabled"], path: "\(path).enabled")
        }
        if patch.keys.contains("allowInsecureHTTP") {
            profile.allowInsecureHTTP = try requiredBool(
                patch["allowInsecureHTTP"],
                path: "\(path).allowInsecureHTTP"
            )
        }
        if patch.keys.contains("allowCredentialRedirects") {
            profile.allowCredentialRedirects = try requiredBool(
                patch["allowCredentialRedirects"],
                path: "\(path).allowCredentialRedirects"
            )
        }
        if patch.keys.contains("auth") {
            profile.auth = try applyingAuthPatch(
                patch["auth"],
                to: profile.auth,
                path: "\(path).auth"
            )
        }
        if patch.keys.contains("headers") {
            profile.headers = try parseHeaders(
                patch["headers"],
                existing: original.headers,
                path: "\(path).headers"
            )
        }
        if patch.keys.contains("agent") {
            if patch["agent"] is NSNull {
                profile.agent = nil
            } else {
                profile.agent = try applyingAgentPatch(
                    patch["agent"],
                    to: profile.agent,
                    path: "\(path).agent"
                )
            }
        }
        if patch.keys.contains("generation") {
            if patch["generation"] is NSNull {
                profile.generation = nil
            } else {
                profile.generation = try applyingGenerationPatch(
                    patch["generation"],
                    to: profile.generation,
                    path: "\(path).generation"
                )
            }
        }
        return profile
    }

    private static func applyingAuthPatch(
        _ rawValue: Any?,
        to original: ProviderAuthConfiguration,
        path: String
    ) throws -> ProviderAuthConfiguration {
        guard let patch = rawValue as? [String: Any] else {
            throw ToolError("\(path): expected object")
        }
        try validateUnknownKeys(
            patch,
            allowed: ["kind", "headerName", "valuePrefix"],
            path: path
        )

        var auth = original
        if patch.keys.contains("kind") {
            let rawKind = try requiredString(patch["kind"], path: "\(path).kind")
            guard let kind = ProviderAuthKind(rawValue: rawKind), kind != .palmierManaged else {
                throw ToolError("\(path).kind: unsupported auth kind '\(rawKind)'")
            }
            auth.kind = kind
            if kind != .customHeader, !patch.keys.contains("headerName") {
                auth.headerName = nil
            }
        }
        if patch.keys.contains("headerName") {
            auth.headerName = try nullableString(patch["headerName"], path: "\(path).headerName")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if patch.keys.contains("valuePrefix") {
            let value = try nullableString(patch["valuePrefix"], path: "\(path).valuePrefix")
            auth.valuePrefix = value?.isEmpty == false ? value : nil
        }
        return auth
    }

    private static func parseHeaders(
        _ rawValue: Any?,
        existing: [ProviderHeaderConfiguration],
        path: String
    ) throws -> [ProviderHeaderConfiguration] {
        guard let rawHeaders = rawValue as? [Any] else {
            throw ToolError("\(path): expected array")
        }

        var usedIDs = Set<UUID>()
        var result: [ProviderHeaderConfiguration] = []
        for (index, rawHeader) in rawHeaders.enumerated() {
            let rowPath = "\(path)[\(index)]"
            guard let row = rawHeader as? [String: Any] else {
                throw ToolError("\(rowPath): expected object")
            }
            try validateUnknownKeys(row, allowed: ["id", "name", "value", "isSecret"], path: rowPath)
            let name = try requiredString(row["name"], path: "\(rowPath).name")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isSecret = try requiredBool(row["isSecret"], path: "\(rowPath).isSecret")
            if isSecret, row.keys.contains("value") {
                throw ToolError("\(rowPath).value: secret values must be entered with action='set_credentials'")
            }

            let id: UUID
            if row.keys.contains("id") {
                let rawID = try requiredString(row["id"], path: "\(rowPath).id")
                guard let parsed = UUID(uuidString: rawID) else {
                    throw ToolError("\(rowPath).id: invalid UUID")
                }
                id = parsed
            } else if let matched = existing.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
                    && $0.isSecret == isSecret
                    && !usedIDs.contains($0.id)
            }) {
                id = matched.id
            } else {
                id = UUID()
            }
            guard usedIDs.insert(id).inserted else {
                throw ToolError("\(rowPath).id: duplicate header id")
            }

            let value: String?
            if isSecret || !row.keys.contains("value") {
                value = nil
            } else {
                value = try nullableString(row["value"], path: "\(rowPath).value")
            }
            result.append(ProviderHeaderConfiguration(id: id, name: name, value: value, isSecret: isSecret))
        }
        return result
    }

    private static func applyingAgentPatch(
        _ rawValue: Any?,
        to original: AgentEndpointConfiguration?,
        path: String
    ) throws -> AgentEndpointConfiguration {
        guard let patch = rawValue as? [String: Any] else {
            throw ToolError("\(path): expected object or null")
        }
        try validateUnknownKeys(
            patch,
            allowed: [
                "protocol", "endpointPath", "defaultModelId", "models",
                "maxOutputTokens", "additionalBody",
            ],
            path: path
        )

        let oldProtocol = original?.wireProtocol ?? .openAIResponses
        var configuration = original ?? AgentEndpointConfiguration(
            wireProtocol: oldProtocol,
            defaultModelID: ""
        )
        if patch.keys.contains("protocol") {
            let rawProtocol = try requiredString(patch["protocol"], path: "\(path).protocol")
            guard let wireProtocol = AgentWireProtocol(rawValue: rawProtocol),
                  wireProtocol != .palmierManaged else {
                throw ToolError("\(path).protocol: unsupported protocol '\(rawProtocol)'")
            }
            configuration.wireProtocol = wireProtocol
            if !patch.keys.contains("endpointPath"),
               original == nil || configuration.endpointPath == oldProtocol.defaultEndpointPath {
                configuration.endpointPath = wireProtocol.defaultEndpointPath
            }
        }
        if patch.keys.contains("endpointPath") {
            configuration.endpointPath = try requiredString(
                patch["endpointPath"],
                path: "\(path).endpointPath"
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if patch.keys.contains("defaultModelId") {
            configuration.defaultModelID = try requiredString(
                patch["defaultModelId"],
                path: "\(path).defaultModelId"
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if patch.keys.contains("models") {
            configuration.models = try parseAgentModels(patch["models"], path: "\(path).models")
        }
        if patch.keys.contains("maxOutputTokens") {
            configuration.maxOutputTokens = try requiredInt(
                patch["maxOutputTokens"],
                path: "\(path).maxOutputTokens"
            )
        }
        if patch.keys.contains("additionalBody") {
            configuration.additionalBody = try parseJSONObject(
                patch["additionalBody"],
                path: "\(path).additionalBody"
            )
        }
        configuration.models = normalizedModels(
            configuration.models,
            defaultModelID: configuration.defaultModelID
        )
        return configuration
    }

    private static func applyingGenerationPatch(
        _ rawValue: Any?,
        to original: GenerationEndpointConfiguration?,
        path: String
    ) throws -> GenerationEndpointConfiguration {
        guard let patch = rawValue as? [String: Any] else {
            throw ToolError("\(path): expected object or null")
        }
        try validateUnknownKeys(
            patch,
            allowed: ["kind", "endpointPath", "modelIds", "options"],
            path: path
        )

        var configuration = original ?? GenerationEndpointConfiguration(providerKind: .compatibleV1)
        if patch.keys.contains("kind") {
            let rawKind = try requiredString(patch["kind"], path: "\(path).kind")
            guard let kind = GenerationProviderKind(rawValue: rawKind), kind != .palmierManaged else {
                throw ToolError("\(path).kind: unsupported generation kind '\(rawKind)'")
            }
            configuration.providerKind = kind
        }
        if patch.keys.contains("endpointPath") {
            configuration.endpointPath = try nullableString(
                patch["endpointPath"],
                path: "\(path).endpointPath"
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if patch.keys.contains("modelIds") {
            configuration.modelIDs = try parseStringArray(
                patch["modelIds"],
                path: "\(path).modelIds"
            )
        }
        if patch.keys.contains("options") {
            configuration.options = try parseJSONObject(patch["options"], path: "\(path).options")
        }
        return configuration
    }

    private static func parseAgentModels(_ rawValue: Any?, path: String) throws -> [AgentModelOption] {
        guard let rawModels = rawValue as? [Any] else {
            throw ToolError("\(path): expected array")
        }
        return try rawModels.enumerated().map { index, rawModel in
            let itemPath = "\(path)[\(index)]"
            if let modelID = rawModel as? String {
                return AgentModelOption(modelID: modelID.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            guard let object = rawModel as? [String: Any] else {
                throw ToolError("\(itemPath): expected string or object")
            }
            try validateUnknownKeys(object, allowed: ["id", "displayName"], path: itemPath)
            let modelID = try requiredString(object["id"], path: "\(itemPath).id")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = object.keys.contains("displayName")
                ? try nullableString(object["displayName"], path: "\(itemPath).displayName")
                : nil
            return AgentModelOption(modelID: modelID, displayName: displayName)
        }
    }

    private static func normalizedModels(
        _ models: [AgentModelOption],
        defaultModelID: String
    ) -> [AgentModelOption] {
        var seen = Set<String>()
        var result: [AgentModelOption] = []
        for model in models {
            let modelID = model.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelID.isEmpty, seen.insert(modelID).inserted else { continue }
            let displayName = model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(AgentModelOption(
                modelID: modelID,
                displayName: displayName.isEmpty ? modelID : displayName
            ))
        }
        let defaultID = defaultModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !defaultID.isEmpty, seen.insert(defaultID).inserted {
            result.insert(AgentModelOption(modelID: defaultID), at: 0)
        }
        return result
    }

    private static func parseStringArray(_ rawValue: Any?, path: String) throws -> [String] {
        guard let rawValues = rawValue as? [Any] else {
            throw ToolError("\(path): expected array")
        }
        var seen = Set<String>()
        var result: [String] = []
        for (index, rawValue) in rawValues.enumerated() {
            guard let value = rawValue as? String else {
                throw ToolError("\(path)[\(index)]: expected string")
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private static func parseJSONObject(_ rawValue: Any?, path: String) throws -> [String: JSONValue] {
        guard let object = rawValue as? [String: Any] else {
            throw ToolError("\(path): expected object")
        }
        do {
            return try object.mapValues(JSONValue.init(foundationValue:))
        } catch {
            throw ToolError("\(path): \(error.localizedDescription)")
        }
    }

    private static func allCredentialTargets(
        for profile: AIProviderProfile
    ) -> [AIProviderCredentialTarget] {
        var targets: [AIProviderCredentialTarget] = []
        if profile.requiresPrimaryCredential { targets.append(.primary) }
        targets.append(contentsOf: profile.headers.filter(\.isSecret).map { .secretHeader($0.id) })
        return targets
    }

    private static func applyDefaultBaseURLIfNeeded(to profile: inout AIProviderProfile) {
        guard profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let agent = profile.agent else { return }
        profile.baseURL = agent.wireProtocol.defaultBaseURL
    }

    private static func preset(for identifier: String) -> AIProviderPreset? {
        switch identifier {
        case "openai-responses": .openAIResponses
        case "openai-chat-completions": .openAIChatCompletions
        case "anthropic-messages": .anthropicMessages
        case "fal-queue": .falQueue
        case "openai-media": .openAIMedia
        case "compatible-generation": .compatibleGeneration
        default: nil
        }
    }

    private static func toolIdentifier(for preset: AIProviderPreset) -> String {
        switch preset {
        case .openAIResponses: "openai-responses"
        case .openAIChatCompletions: "openai-chat-completions"
        case .anthropicMessages: "anthropic-messages"
        case .falQueue: "fal-queue"
        case .openAIMedia: "openai-media"
        case .compatibleGeneration: "compatible-generation"
        }
    }

    private static func requiredString(_ rawValue: Any?, path: String) throws -> String {
        guard let value = rawValue as? String else {
            throw ToolError("\(path): expected string")
        }
        return value
    }

    private static func nullableString(_ rawValue: Any?, path: String) throws -> String? {
        if rawValue is NSNull { return nil }
        return try requiredString(rawValue, path: path)
    }

    private static func requiredBool(_ rawValue: Any?, path: String) throws -> Bool {
        guard let value = rawValue as? Bool else {
            throw ToolError("\(path): expected boolean")
        }
        return value
    }

    private static func requiredInt(_ rawValue: Any?, path: String) throws -> Int {
        guard let rawValue, !isJSONBoolean(rawValue) else {
            throw ToolError("\(path): expected integer")
        }
        if let value = rawValue as? Int { return value }
        if let value = rawValue as? Double, let integer = Int(exactly: value) { return integer }
        if let value = rawValue as? NSNumber, let integer = Int(exactly: value.doubleValue) { return integer }
        throw ToolError("\(path): expected integer")
    }
}
