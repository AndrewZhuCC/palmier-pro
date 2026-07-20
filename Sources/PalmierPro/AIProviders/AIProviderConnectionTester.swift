import Foundation

struct AIProviderConnectionCheck: Sendable, Equatable {
    let service: String
    let networkTestPerformed: Bool
    let message: String
    let modelCount: Int?

    var foundationValue: [String: Any] {
        var result: [String: Any] = [
            "service": service,
            "status": "ok",
            "networkTestPerformed": networkTestPerformed,
            "message": message,
        ]
        if let modelCount { result["modelCount"] = modelCount }
        return result
    }
}

struct AIProviderConnectionTestResult: Sendable, Equatable {
    let checks: [AIProviderConnectionCheck]

    var message: String {
        checks.map(\.message).joined(separator: " ")
    }

    var foundationValue: [String: Any] {
        ["checks": checks.map(\.foundationValue)]
    }
}

enum AIProviderConnectionTester {
    typealias AgentTest = @Sendable (AIProviderRuntimeProfile) async throws -> Void
    typealias CompatibleCatalogTest = @Sendable (AIProviderRuntimeProfile) async throws -> Int

    static func test(
        runtimeProfile: AIProviderRuntimeProfile,
        agentTest: @escaping AgentTest = { runtimeProfile in
            try await AgentConnectionTester.test(runtimeProfile: runtimeProfile)
        },
        compatibleCatalogTest: @escaping CompatibleCatalogTest = { runtimeProfile in
            try await CompatibleGenerationCatalog.entries(runtimeProfile: runtimeProfile).count
        }
    ) async throws -> AIProviderConnectionTestResult {
        var checks: [AIProviderConnectionCheck] = []

        if runtimeProfile.profile.agent != nil {
            try await agentTest(runtimeProfile)
            checks.append(AIProviderConnectionCheck(
                service: "agent",
                networkTestPerformed: true,
                message: "Agent connection succeeded.",
                modelCount: nil
            ))
        }

        if let generation = runtimeProfile.profile.generation {
            switch generation.providerKind {
            case .compatibleV1:
                let modelCount = try await compatibleCatalogTest(runtimeProfile)
                guard modelCount > 0 else {
                    throw AIProviderError.invalidConfiguration(
                        "The generation catalog contains no usable models."
                    )
                }
                let networkTestPerformed: Bool
                if case .array(let localModels)? = generation.options["models"], !localModels.isEmpty {
                    networkTestPerformed = false
                } else {
                    networkTestPerformed = true
                }
                checks.append(AIProviderConnectionCheck(
                    service: "generation",
                    networkTestPerformed: networkTestPerformed,
                    message: networkTestPerformed
                        ? "Generation catalog connection succeeded."
                        : "Generation configuration is valid and its local catalog loaded.",
                    modelCount: modelCount
                ))
            case .falQueue:
                _ = try GenerationProviderFactory.make(runtimeProfile: runtimeProfile)
                let modelCount = FalGenerationCatalog.entries(profile: runtimeProfile.profile).count
                guard modelCount > 0 else {
                    throw AIProviderError.invalidConfiguration(
                        "The generation catalog contains no usable models."
                    )
                }
                checks.append(AIProviderConnectionCheck(
                    service: "generation",
                    networkTestPerformed: false,
                    message: "fal.ai configuration and credentials are valid; no billable request was sent.",
                    modelCount: modelCount
                ))
            case .openAIMedia:
                _ = try GenerationProviderFactory.make(runtimeProfile: runtimeProfile)
                let modelCount = OpenAIMediaGenerationCatalog.entries(profile: runtimeProfile.profile).count
                guard modelCount > 0 else {
                    throw AIProviderError.invalidConfiguration(
                        "The generation catalog contains no usable models."
                    )
                }
                checks.append(AIProviderConnectionCheck(
                    service: "generation",
                    networkTestPerformed: false,
                    message: "OpenAI Media configuration and credentials are valid; no billable request was sent.",
                    modelCount: modelCount
                ))
            case .palmierManaged:
                break
            }
        }

        return AIProviderConnectionTestResult(checks: checks)
    }
}
