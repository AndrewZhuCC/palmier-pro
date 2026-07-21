import Foundation

enum VideoEgressProfileCatalog {
    static let defaultProfileID = "openai-sora"

    static let openaiSora = VideoEgressProfile(
        id: defaultProfileID,
        create: .init(
            path: "videos",
            contentType: "multipart/form-data",
            fields: [
                "model": "{{model}}",
                "prompt": "{{prompt}}",
                "seconds": "{{duration}}",
                "size": "{{size}}",
            ]
        ),
        job: .init(
            status: .init(
                path: "videos/{{jobId}}",
                map: [
                    "queued": "queued",
                    "in_progress": "running",
                    "running": "running",
                    "completed": "succeeded",
                    "failed": "failed",
                    "cancelled": "failed",
                ]
            ),
            result: .init(prefer: [], fallbackContentPath: "videos/{{jobId}}/content")
        ),
        capabilities: .init(
            durations: [4, 8, 12],
            aspectRatios: ["16:9", "9:16"],
            resolutions: ["720p", "1080p"],
            supportsFirstFrame: false,
            maxReferenceImages: 0
        )
    )

    /// Magic/Apifox-style Grok: seconds + aspect_ratio + input_reference.
    static let jsonSecondsAspect = VideoEgressProfile(
        id: "json-seconds-aspect",
        create: .init(
            path: "videos",
            contentType: "application/json",
            body: .object([
                "model": .string("{{model}}"),
                "prompt": .string("{{prompt}}"),
                "seconds": .string("{{duration:string}}"),
                "aspect_ratio": .string("{{aspectRatio}}"),
            ]),
            optional: .object([
                "input_reference": .string("{{startFrameURL}}"),
            ])
        ),
        job: .init(
            status: .init(
                path: "videos/{{jobId}}",
                map: defaultJSONStatusMap
            ),
            result: .init(
                prefer: ["download_url", "url", "output.url", "data.url"],
                fallbackContentPath: "videos/{{jobId}}/content"
            )
        ),
        capabilities: .init(
            durations: [4, 8, 12, 15],
            aspectRatios: ["16:9", "9:16"],
            resolutions: ["720p"],
            supportsFirstFrame: true,
            maxReferenceImages: 1
        )
    )

    /// Prompt Hubs Grok: duration int + aspect_ratio + params.resolution + image.
    static let jsonDurationAspect = VideoEgressProfile(
        id: "json-duration-aspect",
        create: .init(
            path: "videos",
            contentType: "application/json",
            body: .object([
                "model": .string("{{model}}"),
                "prompt": .string("{{prompt}}"),
                "duration": .string("{{duration:int}}"),
                "aspect_ratio": .string("{{aspectRatio}}"),
                "n": .number(1),
                "async": .bool(true),
                "params": .object([
                    "resolution": .string("{{resolution}}"),
                ]),
            ]),
            optional: .object([
                "image": .string("{{startFrameURL}}"),
                "images": .string("{{referenceImageURLs}}"),
            ])
        ),
        job: .init(
            status: .init(
                path: "videos/{{jobId}}",
                map: defaultJSONStatusMap
            ),
            result: .init(
                prefer: ["download_url", "url", "output.url", "data.url"],
                fallbackContentPath: "videos/{{jobId}}/content"
            )
        ),
        capabilities: .init(
            durations: [4, 8, 12, 15],
            aspectRatios: ["16:9", "9:16"],
            resolutions: ["720p"],
            supportsFirstFrame: true,
            maxReferenceImages: 4
        )
    )

    private static let defaultJSONStatusMap: [String: String] = [
        "queued": "queued",
        "pending": "queued",
        "processing": "running",
        "in_progress": "running",
        "running": "running",
        "completed": "succeeded",
        "succeeded": "succeeded",
        "failed": "failed",
        "cancelled": "failed",
        "error": "failed",
    ]

    private static let builtins: [String: VideoEgressProfile] = [
        openaiSora.id: openaiSora,
        jsonSecondsAspect.id: jsonSecondsAspect,
        jsonDurationAspect.id: jsonDurationAspect,
    ]

    static func preset(id: String) -> VideoEgressProfile? {
        builtins[id]
    }

    static func allPresetIDs() -> [String] {
        [openaiSora.id, jsonSecondsAspect.id, jsonDurationAspect.id]
    }

    /// Resolve `generation.options.videoProfile` as preset id string or inline object.
    static func resolve(from options: [String: JSONValue]) throws -> VideoEgressProfile {
        guard let raw = options["videoProfile"] else {
            return openaiSora
        }
        switch raw {
        case .string(let id):
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return openaiSora }
            guard let profile = preset(id: trimmed) else {
                throw GenerationProviderError.invalidResponse("videoProfile unknown id")
            }
            try profile.validate()
            return profile
        case .object:
            let data = try JSONSerialization.data(
                withJSONObject: raw.foundationValue,
                options: [.sortedKeys]
            )
            let profile = try JSONDecoder().decode(VideoEgressProfile.self, from: data)
            try profile.validate()
            return profile
        default:
            throw GenerationProviderError.invalidResponse("videoProfile type")
        }
    }
}
