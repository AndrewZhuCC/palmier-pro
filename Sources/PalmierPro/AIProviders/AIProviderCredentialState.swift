import Foundation

enum AIProviderCredentialTarget: Hashable, Sendable {
    case primary
    case secretHeader(UUID)

    var toolIdentifier: String {
        switch self {
        case .primary:
            "primary"
        case .secretHeader(let id):
            id.uuidString.lowercased()
        }
    }

    static func parse(toolIdentifier rawValue: String) -> AIProviderCredentialTarget? {
        if rawValue == "primary" { return .primary }
        return UUID(uuidString: rawValue).map(AIProviderCredentialTarget.secretHeader)
    }
}

struct AIProviderCredentialState: Sendable, Equatable {
    let primaryRequired: Bool
    let primaryPresent: Bool
    let secretHeaderPresence: [UUID: Bool]

    var requiresCredentials: Bool {
        primaryRequired || !secretHeaderPresence.isEmpty
    }

    var isReady: Bool {
        (!primaryRequired || primaryPresent) && secretHeaderPresence.values.allSatisfy { $0 }
    }

    var statusIdentifier: String {
        guard requiresCredentials else { return "not_required" }
        return isReady ? "ready" : "missing"
    }

    func isPresent(_ target: AIProviderCredentialTarget) -> Bool {
        switch target {
        case .primary:
            primaryPresent
        case .secretHeader(let id):
            secretHeaderPresence[id] ?? false
        }
    }
}

struct AIProviderCredentialPromptField: Sendable, Equatable {
    let target: AIProviderCredentialTarget
    let label: String
    let validationName: String

    var formKey: String {
        switch target {
        case .primary:
            "primary_credential"
        case .secretHeader(let id):
            "header_" + id.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        }
    }
}

struct AIProviderCredentialPromptRequest: Sendable, Equatable {
    let providerName: String
    let providerBaseURL: String
    let fields: [AIProviderCredentialPromptField]
}

enum AIProviderCredentialPromptOutcome: Sendable, Equatable {
    case accepted([AIProviderCredentialTarget: String])
    case cancelled
}

protocol AIProviderCredentialPrompting: Sendable {
    func requestCredentials(
        _ request: AIProviderCredentialPromptRequest
    ) async throws -> AIProviderCredentialPromptOutcome
}

enum AIProviderCredentialPromptError: LocalizedError, Equatable {
    case unavailable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The Palmier Pro secure credential prompt is unavailable. Open Settings > AI Providers."
        case .invalidResponse:
            "The secure credential prompt contained an invalid value. No credentials were changed."
        }
    }
}
