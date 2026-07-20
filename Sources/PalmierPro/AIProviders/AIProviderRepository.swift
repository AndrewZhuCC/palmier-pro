import Foundation

protocol AIProviderConfigurationPersisting: Sendable {
    func load() async throws -> AIProviderConfigurationSnapshot
    func save(_ snapshot: AIProviderConfigurationSnapshot) async throws
}

enum AIProviderRepositoryError: LocalizedError {
    case fileTooLarge
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge: "Provider configuration file is too large."
        case .unsupportedVersion(let version): "Provider configuration version \(version) is not supported."
        }
    }
}

actor AIProviderRepository: AIProviderConfigurationPersisting {
    private static let maxFileBytes = 1_048_576

    private let fileURL: URL

    init(fileURL: URL = AIProviderRepository.defaultFileURL) {
        self.fileURL = fileURL
    }

    func load() throws -> AIProviderConfigurationSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return AIProviderConfigurationSnapshot()
        }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard data.count <= Self.maxFileBytes else { throw AIProviderRepositoryError.fileTooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(AIProviderConfigurationSnapshot.self, from: data)
        guard snapshot.version <= AIProviderConfigurationSnapshot.currentVersion else {
            throw AIProviderRepositoryError.unsupportedVersion(snapshot.version)
        }
        return snapshot
    }

    func save(_ snapshot: AIProviderConfigurationSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    nonisolated static var defaultFileURL: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("PalmierPro", isDirectory: true)
            .appendingPathComponent("ai-providers.json")
    }
}
