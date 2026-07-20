import Foundation

enum GenerationAccessError: LocalizedError, Equatable {
    case providerUnavailable(String)
    case palmierSignInRequired(String)
    case palmierPaidPlanRequired(String)
    case palmierCreditsRequired
    case missingCredential(String)

    var errorDescription: String? {
        switch self {
        case .providerUnavailable(let modelID):
            "The provider for model '\(modelID)' is unavailable. Configure it in Settings > Providers."
        case .palmierSignInRequired(let modelID):
            "Model '\(modelID)' uses Palmier. Sign in or select a BYOK model."
        case .palmierPaidPlanRequired(let modelID):
            "Model '\(modelID)' requires a paid Palmier plan. Pick another model or subscribe."
        case .palmierCreditsRequired:
            "Palmier is out of credits. Pick a BYOK model or add credits."
        case .missingCredential(let providerName):
            "Provider '\(providerName)' is missing credentials. Configure Settings > Providers."
        }
    }
}

@MainActor
enum GenerationAccessPolicy {
    static func validate(modelID: String, paidOnly: Bool) throws {
        guard let entry = ModelRegistry.entry(for: modelID),
              let profileID = entry.providerProfileID,
              let profile = AIProviderStore.shared.profile(id: profileID),
              profile.enabled else {
            throw GenerationAccessError.providerUnavailable(modelID)
        }

        if profile.isManagedPalmier {
            guard AccountService.shared.isSignedIn else {
                throw GenerationAccessError.palmierSignInRequired(modelID)
            }
            if paidOnly && !AccountService.shared.isPaid {
                throw GenerationAccessError.palmierPaidPlanRequired(modelID)
            }
            guard AccountService.shared.hasCredits else {
                throw GenerationAccessError.palmierCreditsRequired
            }
        } else if !AIProviderStore.shared.hasCredential(for: profile) {
            throw GenerationAccessError.missingCredential(profile.name)
        }
    }

    static func isAvailable(modelID: String, paidOnly: Bool) -> Bool {
        (try? validate(modelID: modelID, paidOnly: paidOnly)) != nil
    }
}
