import Foundation

struct GenerationProviderRequest: Sendable {
    let modelID: String
    let params: BackendGenerationParams
    let projectID: String?
}

struct GenerationJobHandle: Codable, Sendable, Equatable {
    let providerProfileID: UUID
    let providerKind: GenerationProviderKind
    let remoteID: String
    let statusURL: String?
    let responseURL: String?
    let cancelURL: String?
    let metadata: [String: JSONValue]

    init(
        providerProfileID: UUID,
        providerKind: GenerationProviderKind,
        remoteID: String,
        statusURL: String? = nil,
        responseURL: String? = nil,
        cancelURL: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.providerProfileID = providerProfileID
        self.providerKind = providerKind
        self.remoteID = remoteID
        self.statusURL = statusURL
        self.responseURL = responseURL
        self.cancelURL = cancelURL
        self.metadata = metadata
    }
}

enum GenerationArtifact: Sendable, Equatable {
    case remoteURL(URL)
    case data(Data, fileExtension: String)
}

enum GenerationProviderStart: Sendable, Equatable {
    case job(GenerationJobHandle)
    case completed([GenerationArtifact])
}

enum GenerationProviderUpdate: Sendable, Equatable {
    case queued
    case running(progress: Double?)
    case succeeded([GenerationArtifact])
    case failed(code: String)
}

protocol GenerationProvider: Sendable {
    var runtimeProfile: AIProviderRuntimeProfile { get }

    func uploadReference(fileURL: URL, contentType: String) async throws -> String
    func start(request: GenerationProviderRequest) async throws -> GenerationProviderStart
    func updates(for handle: GenerationJobHandle) -> AsyncThrowingStream<GenerationProviderUpdate, Error>
}

enum GenerationProviderError: LocalizedError, Equatable {
    case missingGenerationService
    case providerMismatch
    case missingCredential
    case unsupported(String)
    case invalidResponse(String)
    case httpStatus(Int)
    case remoteFailure(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingGenerationService:
            "The selected provider does not configure generation."
        case .providerMismatch:
            "The generation job belongs to a different provider."
        case .missingCredential:
            "The selected generation provider is missing credentials."
        case .unsupported(let capability):
            "This provider does not support \(capability)."
        case .invalidResponse(let reason):
            "The provider returned an invalid generation response: \(reason)"
        case .httpStatus(let status):
            "The generation provider returned HTTP \(status)."
        case .remoteFailure(let code):
            "Generation failed (\(code))."
        case .transport(let message):
            "Generation transport failed: \(message)"
        }
    }
}

/// Rejects `modelID` when the profile configures a non-empty generation model allowlist.
enum GenerationProviderModelAllowlist {
    static func validate(modelID: String, generation: GenerationEndpointConfiguration) throws {
        let allowed = generation.modelIDs
        guard !allowed.isEmpty else { return }
        guard allowed.contains(modelID) else {
            throw GenerationProviderError.unsupported(modelID)
        }
    }
}
