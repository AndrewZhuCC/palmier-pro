import Foundation

enum GenerationProviderFactory {
    static func make(
        runtimeProfile: AIProviderRuntimeProfile,
        transport: any AIHTTPTransporting = AIURLSessionTransport.shared
    ) throws -> any GenerationProvider {
        guard let configuration = runtimeProfile.profile.generation else {
            throw GenerationProviderError.missingGenerationService
        }
        switch configuration.providerKind {
        case .palmierManaged:
            return PalmierGenerationProvider(runtimeProfile: runtimeProfile)
        case .falQueue:
            return FalGenerationProvider(runtimeProfile: runtimeProfile, transport: transport)
        case .openAIMedia:
            return OpenAIMediaGenerationProvider(runtimeProfile: runtimeProfile, transport: transport)
        case .compatibleV1:
            return CompatibleGenerationProvider(runtimeProfile: runtimeProfile, transport: transport)
        }
    }
}
