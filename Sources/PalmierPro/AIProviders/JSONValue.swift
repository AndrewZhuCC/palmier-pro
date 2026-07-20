import Foundation

enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    init(foundationValue value: Any) throws {
        switch value {
        case is NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as NSNumber:
            self = .number(value.doubleValue)
        case let value as String:
            self = .string(value)
        case let values as [Any]:
            self = .array(try values.map(JSONValue.init(foundationValue:)))
        case let values as [String: Any]:
            self = .object(try values.mapValues(JSONValue.init(foundationValue:)))
        default:
            throw JSONValueError.unsupportedType(String(describing: type(of: value)))
        }
    }

    var foundationValue: Any {
        switch self {
        case .null:
            NSNull()
        case .bool(let value):
            value
        case .number(let value):
            value
        case .string(let value):
            value
        case .array(let values):
            values.map(\.foundationValue)
        case .object(let values):
            values.mapValues(\.foundationValue)
        }
    }
}

enum JSONValueError: LocalizedError, Equatable {
    case unsupportedType(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedType(let type):
            "Unsupported JSON value type: \(type)"
        }
    }
}
