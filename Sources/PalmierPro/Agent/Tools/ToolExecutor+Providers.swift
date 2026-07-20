import Foundation

extension ToolExecutor {
    func manageAIProviders(_ args: [String: Any]) async -> ToolResult {
        do {
            try validateUnknownKeys(
                args,
                allowed: [
                    "action", "providerId", "preset", "configuration",
                    "operation", "targets", "confirm",
                ],
                path: "manage_ai_providers"
            )
            if !providerStore.isLoaded {
                await providerStore.loadNow()
            }
            if providerStore.profiles.isEmpty, let error = providerStore.lastError {
                throw ToolError("AI provider configuration could not be loaded: \(error)")
            }

            let action = try args.requireString("action")
            switch action {
            case "list":
                return try await listAIProviders()
            case "create":
                let profile = try AIProviderToolCodec.makeProfileForCreate(
                    presetIdentifier: args.string("preset"),
                    configuration: args["configuration"]
                )
                try await providerStore.saveProfile(profile)
                return try await providerReceipt(action: action, profileID: profile.id, changed: true)
            case "update":
                let existing = try providerProfile(from: args)
                guard !existing.isManagedPalmier else {
                    throw ToolError("Palmier-managed provider profiles are read-only.")
                }
                let profile = try AIProviderToolCodec.updateProfile(
                    existing,
                    configuration: args["configuration"]
                )
                try await providerStore.saveProfile(profile)
                return try await providerReceipt(action: action, profileID: profile.id, changed: true)
            case "set_credentials":
                return try await setAIProviderCredentials(args)
            case "set_active":
                let profile = try providerProfile(from: args)
                guard profile.enabled, profile.agent != nil else {
                    throw ToolError("The provider must be enabled and configure an Agent service.")
                }
                try await providerStore.setActiveAgentProfile(id: profile.id)
                return try await providerReceipt(action: action, profileID: profile.id, changed: true)
            case "test":
                let profile = try providerProfile(from: args)
                let runtimeProfile = try await providerStore.runtimeProfile(id: profile.id)
                let testResult = try await AIProviderConnectionTester.test(runtimeProfile: runtimeProfile)
                var payload = testResult.foundationValue
                payload["action"] = action
                payload["providerId"] = profile.id.uuidString.lowercased()
                payload["status"] = "ok"
                return .ok(Self.jsonString(payload) ?? "{}")
            case "delete":
                guard args["confirm"] as? Bool == true else {
                    throw ToolError("manage_ai_providers.delete requires confirm=true")
                }
                let profile = try providerProfile(from: args)
                guard !profile.isManagedPalmier else {
                    throw ToolError("Palmier-managed provider profiles cannot be deleted.")
                }
                try await providerStore.deleteProfile(id: profile.id)
                var payload: [String: Any] = [
                    "action": action,
                    "deletedProviderId": profile.id.uuidString.lowercased(),
                    "status": "ok",
                ]
                if let activeID = providerStore.activeAgentProfileID {
                    payload["activeAgentProviderId"] = activeID.uuidString.lowercased()
                }
                return .ok(Self.jsonString(payload) ?? "{}")
            default:
                throw ToolError(
                    "manage_ai_providers.action: expected list, create, update, set_credentials, set_active, test, or delete"
                )
            }
        } catch let error as ToolError {
            return .error(error.message)
        } catch let error as AIProviderCredentialPromptError {
            return .error(error.localizedDescription)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private func listAIProviders() async throws -> ToolResult {
        var profiles: [[String: Any]] = []
        profiles.reserveCapacity(providerStore.profiles.count)
        for profile in providerStore.profiles {
            let state = try await providerStore.credentialState(for: profile)
            profiles.append(AIProviderToolCodec.summary(
                profile: profile,
                credentialState: state,
                activeAgentProfileID: providerStore.activeAgentProfileID
            ))
        }
        let payload: [String: Any] = [
            "action": "list",
            "presets": AIProviderToolCodec.presetSummaries,
            "profiles": profiles,
        ]
        return .ok(Self.jsonString(payload) ?? "{}")
    }

    private func setAIProviderCredentials(_ args: [String: Any]) async throws -> ToolResult {
        let profile = try providerProfile(from: args)
        guard !profile.isManagedPalmier else {
            throw ToolError("Palmier-managed provider credentials are handled by the signed-in account.")
        }

        let operation = try args.requireString("operation")
        guard ["prompt_missing", "replace", "remove"].contains(operation) else {
            throw ToolError(
                "manage_ai_providers.operation: expected prompt_missing, replace, or remove"
            )
        }
        let state = try await providerStore.credentialState(for: profile)
        let requestedTargets = try credentialTargetIdentifiers(args["targets"])
        let targets = try AIProviderToolCodec.selectedCredentialTargets(
            for: profile,
            state: state,
            operation: operation,
            requestedIdentifiers: requestedTargets
        )
        guard !targets.isEmpty else {
            return try await providerReceipt(
                action: "set_credentials",
                profileID: profile.id,
                changed: false,
                additional: ["operation": operation]
            )
        }

        switch operation {
        case "remove":
            let values = AIProviderToolCodec.removalValues(for: targets)
            try await providerStore.saveProfile(
                profile,
                primaryCredential: values.primary,
                secretHeaderValues: values.headers
            )
        case "prompt_missing", "replace":
            guard let providerCredentialPrompter else {
                throw AIProviderCredentialPromptError.unavailable
            }
            let fields = try AIProviderToolCodec.promptFields(for: targets, profile: profile)
            let outcome = try await providerCredentialPrompter.requestCredentials(
                AIProviderCredentialPromptRequest(
                    providerName: profile.name,
                    providerBaseURL: profile.baseURL,
                    fields: fields
                )
            )
            switch outcome {
            case .cancelled:
                return try await providerReceipt(
                    action: "set_credentials",
                    profileID: profile.id,
                    changed: false,
                    additional: ["operation": operation, "status": "cancelled"]
                )
            case .accepted(let acceptedValues):
                guard Set(acceptedValues.keys) == Set(targets) else {
                    throw AIProviderCredentialPromptError.invalidResponse
                }
                let values = AIProviderToolCodec.credentialValues(acceptedValues)
                try await providerStore.saveProfile(
                    profile,
                    primaryCredential: values.primary,
                    secretHeaderValues: values.headers
                )
            }
        default:
            break
        }

        return try await providerReceipt(
            action: "set_credentials",
            profileID: profile.id,
            changed: true,
            additional: ["operation": operation]
        )
    }

    private func providerReceipt(
        action: String,
        profileID: UUID,
        changed: Bool,
        additional: [String: Any] = [:]
    ) async throws -> ToolResult {
        guard let profile = providerStore.profile(id: profileID) else {
            throw ToolError("AI provider profile not found after '\(action)'.")
        }
        let state = try await providerStore.credentialState(for: profile)
        var payload = AIProviderToolCodec.summary(
            profile: profile,
            credentialState: state,
            activeAgentProfileID: providerStore.activeAgentProfileID
        )
        payload["action"] = action
        payload["changed"] = changed
        payload["status"] = "ok"
        payload.merge(additional) { _, new in new }
        if let warning = providerStore.lastError {
            payload["warning"] = warning
        }
        return .ok(Self.jsonString(payload) ?? "{}")
    }

    private func providerProfile(from args: [String: Any]) throws -> AIProviderProfile {
        guard let rawID = args.string("providerId"), let id = UUID(uuidString: rawID) else {
            throw ToolError("manage_ai_providers.providerId: expected UUID")
        }
        guard let profile = providerStore.profile(id: id) else {
            throw ToolError("AI provider profile not found: \(rawID)")
        }
        return profile
    }

    private func credentialTargetIdentifiers(_ rawValue: Any?) throws -> [String] {
        guard let rawValue else { return [] }
        guard let rawTargets = rawValue as? [Any] else {
            throw ToolError("manage_ai_providers.targets: expected array")
        }
        return try rawTargets.enumerated().map { index, rawTarget in
            guard let target = rawTarget as? String else {
                throw ToolError("manage_ai_providers.targets[\(index)]: expected string")
            }
            return target
        }
    }
}
