import Foundation

enum GenerationModelIdentifier {
    private static let separator = "::"

    static func qualify(profileID: UUID, modelID: String) -> String {
        profileID.uuidString.lowercased() + separator + modelID
    }

    static func parse(_ qualifiedID: String) -> (profileID: UUID, modelID: String)? {
        guard let range = qualifiedID.range(of: separator) else { return nil }
        let profilePart = String(qualifiedID[..<range.lowerBound])
        let modelPart = String(qualifiedID[range.upperBound...])
        guard let profileID = UUID(uuidString: profilePart), !modelPart.isEmpty else { return nil }
        return (profileID, modelPart)
    }
}
