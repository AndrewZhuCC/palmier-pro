import Foundation
import Observation

extension Notification.Name {
    static let aiProviderConfigurationDidChange = Notification.Name(
        "com.palmier.pro.ai-provider-configuration-did-change"
    )
}

enum AIProviderStoreError: LocalizedError {
    case profileNotFound
    case agentServiceMissing
    case duplicateProfileID

    var errorDescription: String? {
        switch self {
        case .profileNotFound: "AI provider profile was not found."
        case .agentServiceMissing: "The selected provider does not configure an Agent service."
        case .duplicateProfileID: "Provider configuration contains duplicate profile identifiers."
        }
    }
}

@Observable
@MainActor
final class AIProviderStore {
    static let shared = AIProviderStore()
    private static let legacyAnthropicProfileID = UUID(
        uuidString: "00000000-0000-4000-8000-000000000002"
    )!

    private(set) var profiles: [AIProviderProfile] = []
    private(set) var activeAgentProfileID: UUID?
    private(set) var credentialProfileIDs: Set<UUID> = []
    private(set) var isLoaded = false
    private(set) var lastError: String?

    var activeAgentProfile: AIProviderProfile? {
        guard let activeAgentProfileID else { return nil }
        return profiles.first { $0.id == activeAgentProfileID && $0.enabled && $0.agent != nil }
    }

    var agentProfiles: [AIProviderProfile] {
        profiles.filter { $0.enabled && $0.agent != nil }
    }

    var generationProfiles: [AIProviderProfile] {
        profiles.filter { $0.enabled && $0.generation != nil }
    }

    private let repository: any AIProviderConfigurationPersisting
    private let credentials: any AIProviderCredentialStoring
    private let userDefaults: UserDefaults
    private var didConfigure = false

    private convenience init() {
        self.init(
            repository: AIProviderRepository(),
            credentials: AIProviderCredentialVault(),
            userDefaults: .standard
        )
    }

    init(
        repository: any AIProviderConfigurationPersisting,
        credentials: any AIProviderCredentialStoring,
        userDefaults: UserDefaults
    ) {
        self.repository = repository
        self.credentials = credentials
        self.userDefaults = userDefaults
    }

    func configure() {
        guard !didConfigure else { return }
        didConfigure = true
        Task { await loadNow() }
    }

    func loadNow() async {
        do {
            var snapshot = try await repository.load()
            try validateLoadedProfiles(snapshot.profiles)
            var changed = ensureManagedProfile(in: &snapshot)
            var migratedProfileID: UUID?

            let hasConfiguredAgent = snapshot.profiles.contains {
                $0.agent != nil && !$0.isManagedPalmier
            }
            if !hasConfiguredAgent,
               let legacyCredential = try await credentials.legacyAnthropicCredential(),
               !legacyCredential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let model = userDefaults.string(forKey: "agentModel") ?? "claude-sonnet-5"
                var profile = AIProviderProfile.anthropic(apiModel: model)
                profile.id = Self.legacyAnthropicProfileID
                try await credentials.setPrimaryCredential(legacyCredential, for: profile.id)
                snapshot.profiles.append(profile)
                snapshot.activeAgentProfileID = profile.id
                changed = true
                migratedProfileID = profile.id
            }

            let enabledAgentIDs = Set(snapshot.profiles.filter { $0.enabled && $0.agent != nil }.map(\.id))
            if snapshot.activeAgentProfileID.map({ enabledAgentIDs.contains($0) }) != true {
                snapshot.activeAgentProfileID = snapshot.profiles.first {
                    $0.enabled && $0.agent != nil && !$0.isManagedPalmier
                }?.id ?? snapshot.profiles.first { $0.enabled && $0.agent != nil }?.id
                changed = true
            }

            if changed {
                do {
                    try await repository.save(snapshot)
                } catch {
                    if let migratedProfileID {
                        do {
                            try await credentials.removeCredentials(
                                profileID: migratedProfileID,
                                headerIDs: []
                            )
                        } catch {
                            Log.agent.warning(
                                "legacy provider migration rollback failed",
                                telemetry: "Legacy provider migration rollback failed"
                            )
                        }
                    }
                    throw error
                }
            }

            profiles = snapshot.profiles
            activeAgentProfileID = snapshot.activeAgentProfileID
            do {
                credentialProfileIDs = try await credentialIDs(in: snapshot.profiles)
                lastError = nil
            } catch {
                credentialProfileIDs = []
                lastError = "Provider profiles loaded, but Keychain readiness could not be checked."
                Log.agent.warning(
                    "provider credential readiness check failed",
                    telemetry: "Provider credential readiness check failed"
                )
            }
            isLoaded = true

            if migratedProfileID != nil
                || snapshot.profiles.contains(where: { $0.id == Self.legacyAnthropicProfileID }) {
                do {
                    try await credentials.removeLegacyAnthropicCredential()
                } catch {
                    lastError = "Provider configuration loaded, but legacy credential cleanup failed."
                    Log.agent.warning(
                        "legacy provider credential cleanup failed",
                        telemetry: "Legacy provider credential cleanup failed"
                    )
                }
            }

            NotificationCenter.default.post(name: .aiProviderConfigurationDidChange, object: nil)
        } catch {
            isLoaded = true
            lastError = error.localizedDescription
            Log.agent.error(
                "provider configuration load failed",
                telemetry: "AI provider configuration load failed"
            )
        }
    }

    func profile(id: UUID) -> AIProviderProfile? {
        profiles.first { $0.id == id }
    }

    func hasCredential(for profile: AIProviderProfile) -> Bool {
        profile.isManagedPalmier || credentialProfileIDs.contains(profile.id)
    }

    func saveProfile(
        _ rawProfile: AIProviderProfile,
        primaryCredential: String? = nil,
        secretHeaderValues: [UUID: String] = [:]
    ) async throws {
        var profile = rawProfile
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !profile.isManagedPalmier {
            profile.baseURL = try AIProviderEndpoint.normalizedBaseURL(
                profile.baseURL,
                allowInsecureHTTP: profile.allowInsecureHTTP
            ).absoluteString
        }
        profile.updatedAt = Date()
        try AIProviderEndpoint.validate(profile)

        var updated = profiles
        let previousProfile = updated.first(where: { $0.id == profile.id })
        if let index = updated.firstIndex(where: { $0.id == profile.id }) {
            updated[index] = profile
        } else {
            updated.append(profile)
        }
        var activeID = activeAgentProfileID
        if activeID == nil, profile.enabled, profile.agent != nil { activeID = profile.id }

        let previousPrimaryCredential: String?
        if primaryCredential != nil {
            previousPrimaryCredential = try await credentials.primaryCredential(for: profile.id)
        } else {
            previousPrimaryCredential = nil
        }
        var previousSecretValues: [UUID: String?] = [:]
        for header in profile.headers where header.isSecret && secretHeaderValues[header.id] != nil {
            previousSecretValues.updateValue(
                try await credentials.secretHeaderValue(
                    profileID: profile.id,
                    headerID: header.id
                ),
                forKey: header.id
            )
        }

        do {
            if let primaryCredential {
                try await credentials.setPrimaryCredential(primaryCredential, for: profile.id)
            }
            for header in profile.headers where header.isSecret {
                if let value = secretHeaderValues[header.id] {
                    try await credentials.setSecretHeaderValue(
                        value,
                        profileID: profile.id,
                        headerID: header.id
                    )
                }
            }
            try await repository.save(snapshot(profiles: updated, activeAgentProfileID: activeID))
        } catch {
            let persistenceError = error
            var rollbackFailed = false
            if primaryCredential != nil {
                do {
                    try await credentials.setPrimaryCredential(
                        previousPrimaryCredential,
                        for: profile.id
                    )
                } catch {
                    rollbackFailed = true
                }
            }
            for (headerID, previousValue) in previousSecretValues {
                do {
                    try await credentials.setSecretHeaderValue(
                        previousValue,
                        profileID: profile.id,
                        headerID: headerID
                    )
                } catch {
                    rollbackFailed = true
                }
            }
            if rollbackFailed {
                Log.agent.warning(
                    "provider credential rollback failed",
                    telemetry: "Provider credential rollback failed"
                )
            }
            throw persistenceError
        }

        // Metadata is committed. Publish it before best-effort cleanup of credentials no longer used.
        profiles = updated
        activeAgentProfileID = activeID
        var cleanupFailed = false
        if let previousProfile {
            let retainedSecretIDs = Set(profile.headers.filter(\.isSecret).map(\.id))
            for removedHeader in previousProfile.headers where removedHeader.isSecret && !retainedSecretIDs.contains(removedHeader.id) {
                do {
                    try await credentials.setSecretHeaderValue(
                        nil,
                        profileID: profile.id,
                        headerID: removedHeader.id
                    )
                } catch {
                    cleanupFailed = true
                }
            }
            if previousProfile.requiresPrimaryCredential, !profile.requiresPrimaryCredential {
                do {
                    try await credentials.setPrimaryCredential(nil, for: profile.id)
                } catch {
                    cleanupFailed = true
                }
            }
        }

        do {
            credentialProfileIDs = try await credentialIDs(in: updated)
            lastError = cleanupFailed
                ? "Provider saved, but an unused credential could not be removed from Keychain."
                : nil
        } catch {
            credentialProfileIDs.remove(profile.id)
            lastError = "Provider saved, but Keychain readiness could not be checked."
            Log.agent.warning(
                "provider credential readiness refresh failed",
                telemetry: "Provider credential readiness refresh failed"
            )
        }
        if cleanupFailed {
            Log.agent.warning(
                "unused provider credential cleanup failed",
                telemetry: "Unused provider credential cleanup failed"
            )
        }
        NotificationCenter.default.post(name: .aiProviderConfigurationDidChange, object: nil)
    }

    func deleteProfile(id: UUID) async throws {
        guard let profile = profiles.first(where: { $0.id == id }), !profile.isManagedPalmier else { return }
        let updated = profiles.filter { $0.id != id }
        let nextActive = activeAgentProfileID == id
            ? updated.first { $0.enabled && $0.agent != nil }?.id
            : activeAgentProfileID
        try await repository.save(snapshot(profiles: updated, activeAgentProfileID: nextActive))
        profiles = updated
        activeAgentProfileID = nextActive
        credentialProfileIDs.remove(id)
        do {
            try await credentials.removeCredentials(
                profileID: id,
                headerIDs: profile.headers.filter(\.isSecret).map(\.id)
            )
            lastError = nil
        } catch {
            lastError = "Provider deleted, but its unused credential could not be removed from Keychain."
            Log.agent.warning(
                "deleted provider credential cleanup failed",
                telemetry: "Deleted provider credential cleanup failed"
            )
        }
        NotificationCenter.default.post(name: .aiProviderConfigurationDidChange, object: nil)
    }

    func setActiveAgentProfile(id: UUID) async throws {
        guard profiles.contains(where: { $0.id == id && $0.enabled && $0.agent != nil }) else {
            throw AIProviderStoreError.profileNotFound
        }
        try await repository.save(snapshot(profiles: profiles, activeAgentProfileID: id))
        activeAgentProfileID = id
    }

    func runtimeProfile(id: UUID) async throws -> AIProviderRuntimeProfile {
        guard let profile = profile(id: id), profile.enabled else {
            throw AIProviderStoreError.profileNotFound
        }
        return try await runtimeProfile(for: profile)
    }

    func runtimeProfile(
        for profile: AIProviderProfile,
        primaryCredentialOverride: String? = nil,
        secretHeaderOverrides: [UUID: String] = [:]
    ) async throws -> AIProviderRuntimeProfile {
        let storedPrimaryCredential = try await credentials.primaryCredential(for: profile.id)
        let primaryCredential = primaryCredentialOverride?.isEmpty == false
            ? primaryCredentialOverride
            : storedPrimaryCredential
        var secretHeaderValues: [UUID: String] = [:]
        for header in profile.headers where header.isSecret {
            if let override = secretHeaderOverrides[header.id], !override.isEmpty {
                secretHeaderValues[header.id] = override
            } else if let stored = try await credentials.secretHeaderValue(
                profileID: profile.id,
                headerID: header.id
            ) {
                secretHeaderValues[header.id] = stored
            }
        }
        return try AIProviderRuntimeProfile.resolve(
            profile: profile,
            primaryCredential: primaryCredential,
            secretHeaderValues: secretHeaderValues
        )
    }

    func activeAgentRuntimeProfile() async throws -> AIProviderRuntimeProfile {
        guard let activeAgentProfileID else { throw AIProviderStoreError.profileNotFound }
        guard profile(id: activeAgentProfileID)?.agent != nil else {
            throw AIProviderStoreError.agentServiceMissing
        }
        return try await runtimeProfile(id: activeAgentProfileID)
    }

    private func validateLoadedProfiles(_ profiles: [AIProviderProfile]) throws {
        var seen = Set<UUID>()
        for profile in profiles {
            guard seen.insert(profile.id).inserted else {
                throw AIProviderStoreError.duplicateProfileID
            }
            try AIProviderEndpoint.validate(profile)
        }
    }

    private func ensureManagedProfile(in snapshot: inout AIProviderConfigurationSnapshot) -> Bool {
        guard BackendConfig.clerkPublishableKey != nil,
              BackendConfig.convexDeploymentURL != nil,
              let baseURL = BackendConfig.convexHttpURL else { return false }
        guard !snapshot.profiles.contains(where: { $0.id == AIProviderProfile.palmierManagedID }) else {
            return false
        }
        snapshot.profiles.append(.palmierManaged(baseURL: baseURL))
        return true
    }

    private func credentialIDs(in profiles: [AIProviderProfile]) async throws -> Set<UUID> {
        var result = Set<UUID>()
        for profile in profiles {
            var isReady = true
            if profile.requiresPrimaryCredential {
                let credential = try await credentials.primaryCredential(for: profile.id)
                isReady = credential?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
            if isReady {
                for header in profile.headers where header.isSecret {
                    let value = try await credentials.secretHeaderValue(
                        profileID: profile.id,
                        headerID: header.id
                    )
                    if value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                        isReady = false
                        break
                    }
                }
            }
            if isReady {
                result.insert(profile.id)
            }
        }
        return result
    }

    private func snapshot(
        profiles: [AIProviderProfile],
        activeAgentProfileID: UUID?
    ) -> AIProviderConfigurationSnapshot {
        AIProviderConfigurationSnapshot(
            profiles: profiles,
            activeAgentProfileID: activeAgentProfileID
        )
    }
}
