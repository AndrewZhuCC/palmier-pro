import Foundation

enum CompatibleGenerationCatalog {
    static func entries(
        runtimeProfile: AIProviderRuntimeProfile,
        transport: any AIHTTPTransporting = AIURLSessionTransport.shared
    ) async throws -> [CatalogEntry] {
        let profile = runtimeProfile.profile
        guard let generation = profile.generation else {
            throw GenerationProviderError.missingGenerationService
        }
        guard generation.providerKind == .compatibleV1 else {
            throw GenerationProviderError.providerMismatch
        }

        let options = CompatibleGenerationOptions(generation.options)
        let models: [JSONValue]
        if case .array(let local)? = generation.options["models"], !local.isEmpty {
            models = local
        } else {
            models = try await fetchRemoteModels(
                runtimeProfile: runtimeProfile,
                options: options,
                transport: transport
            )
        }

        let allowedIDs = Set(generation.modelIDs)
        var entries: [CatalogEntry] = []
        entries.reserveCapacity(models.count)

        for model in models {
            guard let entry = try parseModelEntry(model, profileID: profile.id) else { continue }
            if !allowedIDs.isEmpty {
                guard let rawID = entry.providerModelID, allowedIDs.contains(rawID) else { continue }
            }
            entries.append(entry)
        }
        return entries
    }

    // MARK: - Network

    private static func fetchRemoteModels(
        runtimeProfile: AIProviderRuntimeProfile,
        options: CompatibleGenerationOptions,
        transport: any AIHTTPTransporting
    ) async throws -> [JSONValue] {
        let root = try CompatibleGenerationEndpoint.root(for: runtimeProfile.profile)
        let url = try CompatibleGenerationEndpoint.resolvePath(
            options.modelsPath,
            root: root,
            allowInsecureHTTP: runtimeProfile.profile.allowInsecureHTTP
        )

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.applyProviderHeaders(runtimeProfile)
        request.setValue("application/json", forHTTPHeaderField: "accept")

        let response: AIHTTPDataResponse
        do {
            response = try await transport.data(for: request, maxResponseBytes: 4 * 1_024 * 1_024)
        } catch let error as AIHTTPTransportError {
            throw GenerationProviderError.transport(error.localizedDescription)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GenerationProviderError.transport(error.localizedDescription)
        }

        guard response.response.statusCode < 400 else {
            throw GenerationProviderError.httpStatus(response.response.statusCode)
        }

        let json: JSONValue
        do {
            json = try JSONDecoder().decode(JSONValue.self, from: response.data)
        } catch {
            throw GenerationProviderError.invalidResponse("models")
        }
        return try extractModelArray(from: json)
    }

    private static func extractModelArray(from json: JSONValue) throws -> [JSONValue] {
        switch json {
        case .array(let values):
            return values
        case .object(let object):
            if case .array(let values)? = object["data"] {
                return values
            }
            if case .array(let values)? = object["models"] {
                return values
            }
            throw GenerationProviderError.invalidResponse("models")
        default:
            throw GenerationProviderError.invalidResponse("models")
        }
    }

    // MARK: - Model parsing

    private static func parseModelEntry(_ value: JSONValue, profileID: UUID) throws -> CatalogEntry? {
        guard case .object(let object) = value else { return nil }

        guard case .string(let rawID) = object["id"], !rawID.isEmpty else {
            throw GenerationProviderError.invalidResponse("model.id")
        }
        guard case .string(let kindRaw) = object["kind"],
              let kind = CatalogEntry.Kind(rawValue: kindRaw) else {
            throw GenerationProviderError.invalidResponse("model.kind")
        }

        let displayName: String
        if case .string(let name) = object["display_name"], !name.isEmpty {
            displayName = name
        } else {
            displayName = rawID
        }

        let capabilitiesObject: [String: JSONValue]
        if case .object(let caps) = object["capabilities"] {
            capabilitiesObject = caps
        } else {
            capabilitiesObject = [:]
        }

        let uiCapabilities: CatalogEntry.UICapabilities
        let responseShape: CatalogEntry.ResponseShape
        switch kind {
        case .video:
            uiCapabilities = .video(parseVideoCaps(capabilitiesObject))
            responseShape = .video
        case .image:
            uiCapabilities = .image(parseImageCaps(capabilitiesObject))
            responseShape = .images
        case .audio:
            uiCapabilities = .audio(parseAudioCaps(capabilitiesObject))
            responseShape = .audio
        case .upscale:
            uiCapabilities = .upscale(parseUpscaleCaps(capabilitiesObject))
            responseShape = .upscaledImage
        }

        return CatalogEntry(
            id: GenerationModelIdentifier.qualify(profileID: profileID, modelID: rawID),
            providerProfileID: profileID,
            providerKind: .compatibleV1,
            providerModelID: rawID,
            kind: kind,
            displayName: displayName,
            responseShape: responseShape,
            uiCapabilities: uiCapabilities,
            allowedEndpoints: [],
            creditsPerSecond: nil,
            audioDiscountRate: nil,
            creditsPerImage: nil,
            qualities: nil,
            audioPricing: nil,
            creditsPerSecondUpscale: nil,
            paidOnly: false
        )
    }

    // MARK: - Capabilities

    private static func parseVideoCaps(_ caps: [String: JSONValue]) -> VideoCaps {
        VideoCaps(
            durations: CompatibleJSON.intArray(caps["durations"]) ?? [],
            resolutions: CompatibleJSON.stringArray(caps["resolutions"]),
            aspectRatios: CompatibleJSON.stringArray(caps["aspect_ratios"]) ?? [],
            supportsFirstFrame: CompatibleJSON.bool(caps["supports_first_frame"]) ?? false,
            supportsLastFrame: CompatibleJSON.bool(caps["supports_last_frame"]) ?? false,
            maxReferenceImages: CompatibleJSON.int(caps["max_reference_images"]) ?? 0,
            maxReferenceVideos: CompatibleJSON.int(caps["max_reference_videos"]) ?? 0,
            maxReferenceAudios: CompatibleJSON.int(caps["max_reference_audios"]) ?? 0,
            maxTotalReferences: CompatibleJSON.int(caps["max_total_references"]),
            maxCombinedVideoRefSeconds: CompatibleJSON.double(caps["max_combined_video_ref_seconds"]),
            maxCombinedAudioRefSeconds: CompatibleJSON.double(caps["max_combined_audio_ref_seconds"]),
            framesAndReferencesExclusive: CompatibleJSON.bool(caps["frames_and_references_exclusive"]) ?? false,
            referenceTagNoun: CompatibleJSON.string(caps["reference_tag_noun"]) ?? "Image",
            requiresSourceVideo: CompatibleJSON.bool(caps["requires_source_video"]) ?? false,
            requiresReferenceImage: CompatibleJSON.bool(caps["requires_reference_image"]) ?? false
        )
    }

    private static func parseImageCaps(_ caps: [String: JSONValue]) -> ImageCaps {
        let maxImagesRaw = CompatibleJSON.int(caps["max_images"]) ?? 1
        let maxImages = min(4, max(1, maxImagesRaw))
        return ImageCaps(
            resolutions: CompatibleJSON.stringArray(caps["resolutions"]),
            aspectRatios: CompatibleJSON.stringArray(caps["aspect_ratios"]) ?? [],
            qualities: CompatibleJSON.stringArray(caps["qualities"]),
            supportsImageReference: CompatibleJSON.bool(caps["supports_image_reference"]) ?? false,
            maxImages: maxImages
        )
    }

    private static func parseAudioCaps(_ caps: [String: JSONValue]) -> AudioCaps {
        AudioCaps(
            category: CompatibleJSON.string(caps["category"]) ?? "tts",
            voices: CompatibleJSON.stringArray(caps["voices"]),
            defaultVoice: CompatibleJSON.string(caps["default_voice"]),
            supportsLyrics: CompatibleJSON.bool(caps["supports_lyrics"]) ?? false,
            supportsInstrumental: CompatibleJSON.bool(caps["supports_instrumental"]) ?? false,
            supportsStyleInstructions: CompatibleJSON.bool(caps["supports_style"])
                ?? CompatibleJSON.bool(caps["supports_style_instructions"])
                ?? false,
            durations: CompatibleJSON.intArray(caps["durations"]),
            minPromptLength: CompatibleJSON.int(caps["min_prompt_length"]) ?? 1,
            inputs: CompatibleJSON.stringArray(caps["inputs"]),
            promptLabel: CompatibleJSON.string(caps["prompt_label"]),
            minSeconds: CompatibleJSON.int(caps["min_seconds"]),
            maxSeconds: CompatibleJSON.int(caps["max_seconds"]),
            targetLanguages: CompatibleJSON.stringArray(caps["target_languages"]),
            defaultTargetLanguage: CompatibleJSON.string(caps["default_target_language"])
        )
    }

    private static func parseUpscaleCaps(_ caps: [String: JSONValue]) -> UpscaleCaps {
        UpscaleCaps(
            speed: CompatibleJSON.string(caps["speed"]) ?? "Unknown",
            p75DurationSeconds: CompatibleJSON.int(caps["p75_duration_seconds"]) ?? 0,
            supportedTypes: CompatibleJSON.stringArray(caps["supported_types"]) ?? []
        )
    }
}

// MARK: - Shared option / endpoint helpers

struct CompatibleGenerationOptions: Sendable {
    let modelsPath: String
    let uploadsPath: String
    let jobsPath: String
    let pollIntervalSeconds: Double
    let timeoutSeconds: Double

    init(_ options: [String: JSONValue]) {
        modelsPath = Self.path(options["modelsPath"], default: "models")
        uploadsPath = Self.path(options["uploadsPath"], default: "uploads")
        jobsPath = Self.path(options["jobsPath"], default: "jobs")
        pollIntervalSeconds = Self.clampedDouble(
            options["pollIntervalSeconds"],
            default: 2,
            range: 0.25...30
        )
        timeoutSeconds = Self.clampedDouble(
            options["timeoutSeconds"],
            default: 1_800,
            range: 60...7_200
        )
    }

    private static func path(_ value: JSONValue?, default defaultValue: String) -> String {
        guard case .string(let raw)? = value else { return defaultValue }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultValue : trimmed
    }

    private static func clampedDouble(
        _ value: JSONValue?,
        default defaultValue: Double,
        range: ClosedRange<Double>
    ) -> Double {
        let number: Double
        switch value {
        case .number(let n)?:
            number = n
        default:
            number = defaultValue
        }
        guard number.isFinite else { return defaultValue }
        return min(range.upperBound, max(range.lowerBound, number))
    }
}

enum CompatibleGenerationEndpoint {
    static func root(for profile: AIProviderProfile) throws -> URL {
        let endpointPath = profile.generation?.endpointPath ?? "v1"
        return try AIProviderEndpoint.resolve(
            baseURL: profile.baseURL,
            endpointPath: endpointPath,
            allowInsecureHTTP: profile.allowInsecureHTTP
        )
    }

    static func resolvePath(
        _ path: String,
        root: URL,
        allowInsecureHTTP: Bool
    ) throws -> URL {
        try AIProviderEndpoint.resolve(
            baseURL: root.absoluteString,
            endpointPath: path,
            allowInsecureHTTP: allowInsecureHTTP
        )
    }

    /// Resolves an absolute URL as-is (after scheme/host checks) or a relative path under `root`.
    static func resolveProviderURL(
        _ raw: String,
        root: URL,
        allowInsecureHTTP: Bool,
        allowCrossHost: Bool = false
    ) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GenerationProviderError.invalidResponse("url")
        }

        if let absolute = URL(string: trimmed),
           let scheme = absolute.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           absolute.host != nil {
            if scheme == "http",
               let host = absolute.host,
               !AIProviderEndpoint.isLoopbackHost(host),
               !allowInsecureHTTP {
                throw GenerationProviderError.invalidResponse("url")
            }
            if absolute.host?.caseInsensitiveCompare(root.host ?? "") != .orderedSame,
               !allowCrossHost {
                throw GenerationProviderError.invalidResponse("url")
            }
            return absolute
        }

        let relative = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.isEmpty else {
            throw GenerationProviderError.invalidResponse("url")
        }
        let resolved = try resolvePath(relative, root: root, allowInsecureHTTP: allowInsecureHTTP)
        if resolved.host?.caseInsensitiveCompare(root.host ?? "") != .orderedSame,
           !allowCrossHost {
            throw GenerationProviderError.invalidResponse("url")
        }
        return resolved
    }
}

enum CompatibleJSON {
    static func string(_ value: JSONValue?) -> String? {
        guard case .string(let s)? = value else { return nil }
        return s
    }

    static func bool(_ value: JSONValue?) -> Bool? {
        guard case .bool(let b)? = value else { return nil }
        return b
    }

    static func int(_ value: JSONValue?) -> Int? {
        guard case .number(let n)? = value, n.isFinite else { return nil }
        return Int(n)
    }

    static func double(_ value: JSONValue?) -> Double? {
        guard case .number(let n)? = value, n.isFinite else { return nil }
        return n
    }

    static func stringArray(_ value: JSONValue?) -> [String]? {
        guard case .array(let items)? = value else { return nil }
        var result: [String] = []
        result.reserveCapacity(items.count)
        for item in items {
            guard case .string(let s) = item else { continue }
            result.append(s)
        }
        return result
    }

    static func intArray(_ value: JSONValue?) -> [Int]? {
        guard case .array(let items)? = value else { return nil }
        var result: [Int] = []
        result.reserveCapacity(items.count)
        for item in items {
            guard case .number(let n) = item, n.isFinite else { continue }
            result.append(Int(n))
        }
        return result
    }
}
