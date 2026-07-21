import Foundation

/// Declarative video create/poll/result mapping for OpenAI-Media-compatible gateways.
struct VideoEgressProfile: Codable, Sendable, Equatable {
    var id: String
    var create: Create
    var job: Job
    var capabilities: Capabilities?

    struct Create: Codable, Sendable, Equatable {
        var method: String
        var path: String
        /// `application/json` or `multipart/form-data`
        var contentType: String
        /// JSON body template; string leaves may contain `{{placeholders}}`.
        var body: JSONValue?
        /// Multipart text fields (Sora-style).
        var fields: [String: String]?
        /// Optional fields merged into body/fields when rendered values are non-empty.
        var optional: JSONValue?

        enum CodingKeys: String, CodingKey {
            case method, path, contentType, body, fields, optional
        }

        init(
            method: String = "POST",
            path: String,
            contentType: String,
            body: JSONValue? = nil,
            fields: [String: String]? = nil,
            optional: JSONValue? = nil
        ) {
            self.method = method
            self.path = path
            self.contentType = contentType
            self.body = body
            self.fields = fields
            self.optional = optional
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            method = try c.decodeIfPresent(String.self, forKey: .method) ?? "POST"
            path = try c.decode(String.self, forKey: .path)
            contentType = try c.decode(String.self, forKey: .contentType)
            body = try c.decodeIfPresent(JSONValue.self, forKey: .body)
            fields = try c.decodeIfPresent([String: String].self, forKey: .fields)
            optional = try c.decodeIfPresent(JSONValue.self, forKey: .optional)
        }
    }

    struct Job: Codable, Sendable, Equatable {
        var idPath: String
        var status: Status
        var result: Result

        enum CodingKeys: String, CodingKey {
            case idPath, status, result
        }

        init(idPath: String = "id", status: Status, result: Result) {
            self.idPath = idPath
            self.status = status
            self.result = result
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            idPath = try c.decodeIfPresent(String.self, forKey: .idPath) ?? "id"
            status = try c.decode(Status.self, forKey: .status)
            result = try c.decode(Result.self, forKey: .result)
        }
    }

    struct Status: Codable, Sendable, Equatable {
        var method: String
        var path: String
        var statusPath: String
        var progressPath: String?
        /// Raw provider status → `queued` | `running` | `succeeded` | `failed`
        var map: [String: String]

        enum CodingKeys: String, CodingKey {
            case method, path, statusPath, progressPath, map
        }

        init(
            method: String = "GET",
            path: String,
            statusPath: String = "status",
            progressPath: String? = "progress",
            map: [String: String]
        ) {
            self.method = method
            self.path = path
            self.statusPath = statusPath
            self.progressPath = progressPath
            self.map = map
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            method = try c.decodeIfPresent(String.self, forKey: .method) ?? "GET"
            path = try c.decode(String.self, forKey: .path)
            statusPath = try c.decodeIfPresent(String.self, forKey: .statusPath) ?? "status"
            progressPath = try c.decodeIfPresent(String.self, forKey: .progressPath)
            map = try c.decode([String: String].self, forKey: .map)
        }
    }

    struct Result: Codable, Sendable, Equatable {
        /// Dot-paths tried in order for a downloadable http(s) URL.
        var prefer: [String]
        /// Relative path template when binary content is at a fixed endpoint.
        var fallbackContentPath: String?

        init(prefer: [String] = [], fallbackContentPath: String? = nil) {
            self.prefer = prefer
            self.fallbackContentPath = fallbackContentPath
        }
    }

    struct Capabilities: Codable, Sendable, Equatable {
        var durations: [Int]?
        var aspectRatios: [String]?
        var resolutions: [String]?
        var supportsFirstFrame: Bool?
        var maxReferenceImages: Int?

        init(
            durations: [Int]? = nil,
            aspectRatios: [String]? = nil,
            resolutions: [String]? = nil,
            supportsFirstFrame: Bool? = nil,
            maxReferenceImages: Int? = nil
        ) {
            self.durations = durations
            self.aspectRatios = aspectRatios
            self.resolutions = resolutions
            self.supportsFirstFrame = supportsFirstFrame
            self.maxReferenceImages = maxReferenceImages
        }
    }

    func validate() throws {
        let path = create.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw GenerationProviderError.invalidResponse("videoProfile.create.path")
        }
        let ct = create.contentType.lowercased()
        guard ct == "application/json" || ct == "multipart/form-data" else {
            throw GenerationProviderError.invalidResponse("videoProfile.create.contentType")
        }
        if ct == "application/json", create.body == nil, create.optional == nil {
            throw GenerationProviderError.invalidResponse("videoProfile.create.body")
        }
        if ct == "multipart/form-data", (create.fields ?? [:]).isEmpty {
            throw GenerationProviderError.invalidResponse("videoProfile.create.fields")
        }
        guard !job.status.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GenerationProviderError.invalidResponse("videoProfile.job.status.path")
        }
        guard !job.status.map.isEmpty else {
            throw GenerationProviderError.invalidResponse("videoProfile.job.status.map")
        }
        let allowed = Set(["queued", "running", "succeeded", "failed"])
        for value in job.status.map.values {
            guard allowed.contains(value) else {
                throw GenerationProviderError.invalidResponse("videoProfile.job.status.map")
            }
        }
    }
}

enum VideoEgressNormalizedStatus: String, Sendable {
    case queued
    case running
    case succeeded
    case failed
}
