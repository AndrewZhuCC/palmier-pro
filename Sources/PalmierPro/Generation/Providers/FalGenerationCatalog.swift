import Foundation

enum FalGenerationCatalog {
    struct FalRequestDefinition: Sendable, Equatable {
        let endpoint: String
        let body: [String: JSONValue]
        let responseShape: CatalogEntry.ResponseShape
    }

    // MARK: - Entries

    static func entries(profile: AIProviderProfile) -> [CatalogEntry] {
        let allowed = Set(profile.generation?.modelIDs ?? [])
        var result: [CatalogEntry] = []
        result.reserveCapacity(allDescriptors.count)
        for descriptor in allDescriptors {
            if !allowed.isEmpty, !allowed.contains(descriptor.rawID) { continue }
            result.append(makeEntry(descriptor, profileID: profile.id))
        }
        return result
    }

    // MARK: - Request

    static func request(modelID: String, params: BackendGenerationParams) throws -> FalRequestDefinition {
        switch params {
        case .video(let video):
            return try videoRequest(modelID: modelID, params: video)
        case .image(let image):
            return try imageRequest(modelID: modelID, params: image)
        case .audio(let audio):
            return try audioRequest(modelID: modelID, params: audio)
        case .upscale(let upscale):
            return try upscaleRequest(modelID: modelID, params: upscale)
        }
    }

    // MARK: - Descriptor

    private struct ModelDescriptor: Sendable {
        let rawID: String
        let displayName: String
        let kind: CatalogEntry.Kind
        let responseShape: CatalogEntry.ResponseShape
        let uiCapabilities: CatalogEntry.UICapabilities
    }

    private static func makeEntry(_ descriptor: ModelDescriptor, profileID: UUID) -> CatalogEntry {
        CatalogEntry(
            id: GenerationModelIdentifier.qualify(profileID: profileID, modelID: descriptor.rawID),
            providerProfileID: profileID,
            providerKind: .falQueue,
            providerModelID: descriptor.rawID,
            kind: descriptor.kind,
            displayName: descriptor.displayName,
            responseShape: descriptor.responseShape,
            uiCapabilities: descriptor.uiCapabilities,
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

    private static let allDescriptors: [ModelDescriptor] = {
        var items: [ModelDescriptor] = []
        items.append(contentsOf: videoDescriptors)
        items.append(contentsOf: imageDescriptors)
        items.append(contentsOf: audioDescriptors)
        items.append(contentsOf: upscaleDescriptors)
        return items
    }()

    // MARK: - Video descriptors

    private static let videoDescriptors: [ModelDescriptor] = [
        video(
            rawID: "seedance-2",
            displayName: "Seedance 2",
            durations: Array(4...15),
            resolutions: ["480p", "720p", "1080p"],
            aspectRatios: ["auto", "21:9", "16:9", "4:3", "1:1", "3:4", "9:16"],
            supportsFirstFrame: true,
            supportsLastFrame: true,
            maxReferenceImages: 9,
            maxReferenceVideos: 3,
            maxReferenceAudios: 3,
            maxTotalReferences: 12,
            maxCombinedVideoRefSeconds: 15,
            maxCombinedAudioRefSeconds: 15,
            framesAndReferencesExclusive: true,
            referenceTagNoun: "Image",
            requiresSourceVideo: false
        ),
        video(
            rawID: "seedance-2-fast",
            displayName: "Seedance 2 Fast",
            durations: Array(4...15),
            resolutions: ["480p", "720p"],
            aspectRatios: ["auto", "21:9", "16:9", "4:3", "1:1", "3:4", "9:16"],
            supportsFirstFrame: true,
            supportsLastFrame: true,
            maxReferenceImages: 9,
            maxReferenceVideos: 3,
            maxReferenceAudios: 3,
            maxTotalReferences: 12,
            maxCombinedVideoRefSeconds: 15,
            maxCombinedAudioRefSeconds: 15,
            framesAndReferencesExclusive: true,
            referenceTagNoun: "Image",
            requiresSourceVideo: false
        ),
        video(
            rawID: "kling-o3",
            displayName: "Kling O3",
            durations: Array(3...15),
            resolutions: ["1080p", "4k"],
            aspectRatios: ["16:9", "9:16", "1:1"],
            supportsFirstFrame: true,
            supportsLastFrame: true,
            maxReferenceImages: 7,
            maxReferenceVideos: 0,
            maxReferenceAudios: 0,
            maxTotalReferences: nil,
            maxCombinedVideoRefSeconds: nil,
            maxCombinedAudioRefSeconds: nil,
            framesAndReferencesExclusive: false,
            referenceTagNoun: "Element",
            requiresSourceVideo: false
        ),
        video(
            rawID: "kling-v3",
            displayName: "Kling V3",
            durations: Array(3...15),
            resolutions: ["1080p", "4k"],
            aspectRatios: ["16:9", "9:16", "1:1"],
            supportsFirstFrame: true,
            supportsLastFrame: true,
            maxReferenceImages: 3,
            maxReferenceVideos: 0,
            maxReferenceAudios: 0,
            maxTotalReferences: nil,
            maxCombinedVideoRefSeconds: nil,
            maxCombinedAudioRefSeconds: nil,
            framesAndReferencesExclusive: false,
            referenceTagNoun: "Element",
            requiresSourceVideo: false
        ),
        video(
            rawID: "veo3.1",
            displayName: "Veo 3.1",
            durations: [4, 6, 8],
            resolutions: ["720p", "1080p", "4k"],
            aspectRatios: ["16:9", "9:16"],
            supportsFirstFrame: true,
            supportsLastFrame: true,
            maxReferenceImages: 0,
            maxReferenceVideos: 0,
            maxReferenceAudios: 0,
            maxTotalReferences: nil,
            maxCombinedVideoRefSeconds: nil,
            maxCombinedAudioRefSeconds: nil,
            framesAndReferencesExclusive: false,
            referenceTagNoun: "Image",
            requiresSourceVideo: false
        ),
        video(
            rawID: "veo3.1-fast",
            displayName: "Veo 3.1 Fast",
            durations: [4, 6, 8],
            resolutions: ["720p", "1080p", "4k"],
            aspectRatios: ["16:9", "9:16"],
            supportsFirstFrame: true,
            supportsLastFrame: true,
            maxReferenceImages: 0,
            maxReferenceVideos: 0,
            maxReferenceAudios: 0,
            maxTotalReferences: nil,
            maxCombinedVideoRefSeconds: nil,
            maxCombinedAudioRefSeconds: nil,
            framesAndReferencesExclusive: false,
            referenceTagNoun: "Image",
            requiresSourceVideo: false
        ),
        video(
            rawID: "veo3.1-lite",
            displayName: "Veo 3.1 Lite",
            durations: [4, 6, 8],
            resolutions: ["720p", "1080p"],
            aspectRatios: ["16:9", "9:16"],
            supportsFirstFrame: true,
            supportsLastFrame: true,
            maxReferenceImages: 0,
            maxReferenceVideos: 0,
            maxReferenceAudios: 0,
            maxTotalReferences: nil,
            maxCombinedVideoRefSeconds: nil,
            maxCombinedAudioRefSeconds: nil,
            framesAndReferencesExclusive: false,
            referenceTagNoun: "Image",
            requiresSourceVideo: false
        ),
        video(
            rawID: "grok-imagine-video",
            displayName: "Grok Imagine Video",
            durations: Array(6...15),
            resolutions: ["480p", "720p"],
            aspectRatios: ["16:9", "9:16"],
            supportsFirstFrame: true,
            supportsLastFrame: false,
            maxReferenceImages: 7,
            maxReferenceVideos: 0,
            maxReferenceAudios: 0,
            maxTotalReferences: nil,
            maxCombinedVideoRefSeconds: nil,
            maxCombinedAudioRefSeconds: nil,
            framesAndReferencesExclusive: true,
            referenceTagNoun: "Image",
            requiresSourceVideo: false
        ),
        video(
            rawID: "kling-o3-edit",
            displayName: "Kling O3 Edit",
            durations: [],
            resolutions: nil,
            aspectRatios: [],
            supportsFirstFrame: false,
            supportsLastFrame: false,
            maxReferenceImages: 0,
            maxReferenceVideos: 0,
            maxReferenceAudios: 0,
            maxTotalReferences: nil,
            maxCombinedVideoRefSeconds: nil,
            maxCombinedAudioRefSeconds: nil,
            framesAndReferencesExclusive: false,
            referenceTagNoun: "Image",
            requiresSourceVideo: true
        ),
        video(
            rawID: "kling-v3-motion-control",
            displayName: "Kling V3 Motion Control",
            durations: [],
            resolutions: nil,
            aspectRatios: [],
            supportsFirstFrame: false,
            supportsLastFrame: false,
            maxReferenceImages: 1,
            maxReferenceVideos: 0,
            maxReferenceAudios: 0,
            maxTotalReferences: nil,
            maxCombinedVideoRefSeconds: nil,
            maxCombinedAudioRefSeconds: nil,
            framesAndReferencesExclusive: false,
            referenceTagNoun: "Image",
            requiresSourceVideo: true
        ),
    ]

    private static func video(
        rawID: String,
        displayName: String,
        durations: [Int],
        resolutions: [String]?,
        aspectRatios: [String],
        supportsFirstFrame: Bool,
        supportsLastFrame: Bool,
        maxReferenceImages: Int,
        maxReferenceVideos: Int,
        maxReferenceAudios: Int,
        maxTotalReferences: Int?,
        maxCombinedVideoRefSeconds: Double?,
        maxCombinedAudioRefSeconds: Double?,
        framesAndReferencesExclusive: Bool,
        referenceTagNoun: String,
        requiresSourceVideo: Bool
    ) -> ModelDescriptor {
        ModelDescriptor(
            rawID: rawID,
            displayName: displayName,
            kind: .video,
            responseShape: .video,
            uiCapabilities: .video(VideoCaps(
                durations: durations,
                resolutions: resolutions,
                aspectRatios: aspectRatios,
                supportsFirstFrame: supportsFirstFrame,
                supportsLastFrame: supportsLastFrame,
                maxReferenceImages: maxReferenceImages,
                maxReferenceVideos: maxReferenceVideos,
                maxReferenceAudios: maxReferenceAudios,
                maxTotalReferences: maxTotalReferences,
                maxCombinedVideoRefSeconds: maxCombinedVideoRefSeconds,
                maxCombinedAudioRefSeconds: maxCombinedAudioRefSeconds,
                framesAndReferencesExclusive: framesAndReferencesExclusive,
                referenceTagNoun: referenceTagNoun,
                requiresSourceVideo: requiresSourceVideo,
                requiresReferenceImage: false
            ))
        )
    }

    // MARK: - Image descriptors

    private static let imageDescriptors: [ModelDescriptor] = [
        image(
            rawID: "nano-banana-pro",
            displayName: "Nano Banana Pro",
            resolutions: ["2K", "4K"],
            aspectRatios: ["auto", "21:9", "16:9", "3:2", "4:3", "5:4", "1:1", "4:5", "3:4", "2:3", "9:16"],
            qualities: nil,
            supportsImageReference: true,
            maxImages: 4
        ),
        image(
            rawID: "nano-banana-2",
            displayName: "Nano Banana 2",
            resolutions: ["2K", "4K"],
            aspectRatios: [
                "auto", "21:9", "16:9", "3:2", "4:3", "5:4", "1:1", "4:5", "3:4", "2:3", "9:16",
                "4:1", "1:4", "8:1", "1:8",
            ],
            qualities: nil,
            supportsImageReference: true,
            maxImages: 4
        ),
        image(
            rawID: "grok-imagine",
            displayName: "Grok Imagine",
            resolutions: nil,
            aspectRatios: [
                "2:1", "20:9", "19.5:9", "16:9", "4:3", "3:2", "1:1", "2:3", "3:4", "9:16",
                "9:19.5", "9:20", "1:2",
            ],
            qualities: nil,
            supportsImageReference: true,
            maxImages: 4
        ),
        image(
            rawID: "recraft-v4",
            displayName: "Recraft V4",
            resolutions: nil,
            aspectRatios: [
                "square_hd", "square", "portrait_4_3", "portrait_16_9", "landscape_4_3", "landscape_16_9",
            ],
            qualities: nil,
            supportsImageReference: false,
            maxImages: 4
        ),
        image(
            rawID: "gpt-image-2",
            displayName: "GPT Image 2",
            resolutions: ["1024x768", "1024x1024", "1024x1536", "1920x1080", "2560x1440", "3840x2160"],
            aspectRatios: [],
            qualities: ["low", "medium", "high"],
            supportsImageReference: true,
            maxImages: 1
        ),
    ]

    private static func image(
        rawID: String,
        displayName: String,
        resolutions: [String]?,
        aspectRatios: [String],
        qualities: [String]?,
        supportsImageReference: Bool,
        maxImages: Int
    ) -> ModelDescriptor {
        ModelDescriptor(
            rawID: rawID,
            displayName: displayName,
            kind: .image,
            responseShape: .images,
            uiCapabilities: .image(ImageCaps(
                resolutions: resolutions,
                aspectRatios: aspectRatios,
                qualities: qualities,
                supportsImageReference: supportsImageReference,
                maxImages: maxImages
            ))
        )
    }

    // MARK: - Audio descriptors

    private static let elevenLabsVoices = [
        "Rachel", "Aria", "Roger", "Sarah", "Laura", "Charlie", "George", "Callum",
        "River", "Liam", "Charlotte", "Alice", "Matilda", "Will", "Jessica", "Eric",
        "Chris", "Brian", "Daniel", "Lily", "Bill",
    ]

    private static let geminiVoices = [
        "Kore", "Achernar", "Achird", "Algenib", "Algieba", "Alnilam", "Aoede",
        "Autonoe", "Callirrhoe", "Charon", "Despina", "Enceladus", "Erinome",
        "Fenrir", "Gacrux", "Iapetus", "Laomedeia", "Leda", "Orus", "Pulcherrima",
        "Puck", "Rasalgethi", "Sadachbia", "Sadaltager", "Schedar", "Sulafat",
        "Umbriel", "Vindemiatrix", "Zephyr", "Zubenelgenubi",
    ]

    private static let audioDescriptors: [ModelDescriptor] = [
        audio(
            rawID: "elevenlabs-tts-v3",
            displayName: "ElevenLabs v3 TTS",
            category: "tts",
            voices: elevenLabsVoices,
            defaultVoice: "Rachel",
            supportsLyrics: false,
            supportsInstrumental: false,
            supportsStyleInstructions: false,
            durations: nil,
            minPromptLength: 1,
            inputs: ["text"],
            promptLabel: nil
        ),
        audio(
            rawID: "gemini-3.1-flash-tts",
            displayName: "Gemini 3.1 Flash TTS",
            category: "tts",
            voices: geminiVoices,
            defaultVoice: "Kore",
            supportsLyrics: false,
            supportsInstrumental: false,
            supportsStyleInstructions: true,
            durations: nil,
            minPromptLength: 1,
            inputs: ["text"],
            promptLabel: nil
        ),
        audio(
            rawID: "minimax-music-v2.6",
            displayName: "MiniMax Music 2.6",
            category: "music",
            voices: nil,
            defaultVoice: nil,
            supportsLyrics: true,
            supportsInstrumental: true,
            supportsStyleInstructions: false,
            durations: nil,
            minPromptLength: 10,
            inputs: ["text"],
            promptLabel: nil
        ),
        audio(
            rawID: "elevenlabs-music",
            displayName: "ElevenLabs Music",
            category: "music",
            voices: nil,
            defaultVoice: nil,
            supportsLyrics: false,
            supportsInstrumental: true,
            supportsStyleInstructions: false,
            durations: [15, 30, 60, 90, 120, 180],
            minPromptLength: 1,
            inputs: ["text"],
            promptLabel: nil
        ),
    ]

    private static func audio(
        rawID: String,
        displayName: String,
        category: String,
        voices: [String]?,
        defaultVoice: String?,
        supportsLyrics: Bool,
        supportsInstrumental: Bool,
        supportsStyleInstructions: Bool,
        durations: [Int]?,
        minPromptLength: Int,
        inputs: [String]?,
        promptLabel: String?
    ) -> ModelDescriptor {
        ModelDescriptor(
            rawID: rawID,
            displayName: displayName,
            kind: .audio,
            responseShape: .audio,
            uiCapabilities: .audio(AudioCaps(
                category: category,
                voices: voices,
                defaultVoice: defaultVoice,
                supportsLyrics: supportsLyrics,
                supportsInstrumental: supportsInstrumental,
                supportsStyleInstructions: supportsStyleInstructions,
                durations: durations,
                minPromptLength: minPromptLength,
                inputs: inputs,
                promptLabel: promptLabel,
                minSeconds: nil,
                maxSeconds: nil,
                targetLanguages: nil,
                defaultTargetLanguage: nil
            ))
        )
    }

    // MARK: - Upscale descriptors

    private static let upscaleDescriptors: [ModelDescriptor] = [
        upscale(
            rawID: "bytedance-upscaler",
            displayName: "Bytedance Upscaler",
            speed: "Fast",
            p75DurationSeconds: 130,
            supportedTypes: ["video"],
            responseShape: .video
        ),
        upscale(
            rawID: "seedvr-upscaler",
            displayName: "SeedVR2",
            speed: "Medium",
            p75DurationSeconds: 691,
            supportedTypes: ["video"],
            responseShape: .video
        ),
        upscale(
            rawID: "topaz-upscaler",
            displayName: "Topaz Upscale",
            speed: "Slow",
            p75DurationSeconds: 65,
            supportedTypes: ["video"],
            responseShape: .video
        ),
        upscale(
            rawID: "seedvr-image-upscaler",
            displayName: "SeedVR2",
            speed: "Fast",
            p75DurationSeconds: 19,
            supportedTypes: ["image"],
            responseShape: .upscaledImage
        ),
        upscale(
            rawID: "topaz-image-upscaler",
            displayName: "Topaz Upscale",
            speed: "Medium",
            p75DurationSeconds: 24,
            supportedTypes: ["image"],
            responseShape: .upscaledImage
        ),
    ]

    private static func upscale(
        rawID: String,
        displayName: String,
        speed: String,
        p75DurationSeconds: Int,
        supportedTypes: [String],
        responseShape: CatalogEntry.ResponseShape
    ) -> ModelDescriptor {
        ModelDescriptor(
            rawID: rawID,
            displayName: displayName,
            kind: .upscale,
            responseShape: responseShape,
            uiCapabilities: .upscale(UpscaleCaps(
                speed: speed,
                p75DurationSeconds: p75DurationSeconds,
                supportedTypes: supportedTypes
            ))
        )
    }

    // MARK: - Video request builders

    private static func videoRequest(modelID: String, params: VideoGenerationParams) throws -> FalRequestDefinition {
        switch modelID {
        case "seedance-2":
            return FalRequestDefinition(
                endpoint: seedanceEndpoint(variant: nil, params: params),
                body: buildSeedanceBody(params),
                responseShape: .video
            )
        case "seedance-2-fast":
            return FalRequestDefinition(
                endpoint: seedanceEndpoint(variant: "fast", params: params),
                body: buildSeedanceBody(params),
                responseShape: .video
            )
        case "kling-v3":
            return klingRequest(
                base: "fal-ai/kling-video/v3",
                params: params,
                proResolver: frameOnlyEndpoint,
                proStartFrameKey: "image_url",
                fourKStartFrameKey: "start_image_url"
            )
        case "kling-o3":
            return klingRequest(
                base: "fal-ai/kling-video/o3",
                params: params,
                proResolver: standardVideoEndpoint,
                proStartFrameKey: "start_image_url",
                fourKStartFrameKey: "image_url"
            )
        case "veo3.1":
            return veoRequest(variant: nil, params: params)
        case "veo3.1-fast":
            return veoRequest(variant: "fast", params: params)
        case "veo3.1-lite":
            return veoRequest(variant: "lite", params: params)
        case "grok-imagine-video":
            return grokVideoRequest(params: params)
        case "kling-o3-edit":
            var body: [String: JSONValue] = ["prompt": .string(params.prompt)]
            if let src = params.sourceVideoURL { body["video_url"] = .string(src) }
            return FalRequestDefinition(
                endpoint: "fal-ai/kling-video/o3/pro/video-to-video/edit",
                body: body,
                responseShape: .video
            )
        case "kling-v3-motion-control":
            var body: [String: JSONValue] = ["character_orientation": .string("video")]
            if let src = params.sourceVideoURL { body["video_url"] = .string(src) }
            if let img = params.referenceImageURLs.first { body["image_url"] = .string(img) }
            if !params.prompt.isEmpty { body["prompt"] = .string(params.prompt) }
            return FalRequestDefinition(
                endpoint: "fal-ai/kling-video/v3/pro/motion-control",
                body: body,
                responseShape: .video
            )
        default:
            throw GenerationProviderError.unsupported(modelID)
        }
    }

    private static func hasAnyReferences(_ params: VideoGenerationParams) -> Bool {
        !params.referenceImageURLs.isEmpty
            || !params.referenceVideoURLs.isEmpty
            || !params.referenceAudioURLs.isEmpty
    }

    private static func standardVideoEndpoint(_ base: String, _ params: VideoGenerationParams) -> String {
        if hasAnyReferences(params) { return "\(base)/reference-to-video" }
        if params.startFrameURL != nil { return "\(base)/image-to-video" }
        return "\(base)/text-to-video"
    }

    private static func frameOnlyEndpoint(_ base: String, _ params: VideoGenerationParams) -> String {
        "\(base)/\(params.startFrameURL != nil ? "image-to-video" : "text-to-video")"
    }

    private static func seedanceEndpoint(variant: String?, params: VideoGenerationParams) -> String {
        let base = "bytedance/seedance-2.0"
        let prefix = variant.map { "\(base)/\($0)" } ?? base
        return standardVideoEndpoint(prefix, params)
    }

    private static func buildSeedanceBody(_ params: VideoGenerationParams) -> [String: JSONValue] {
        var body: [String: JSONValue] = ["prompt": .string(params.prompt)]
        if hasAnyReferences(params) {
            if !params.referenceImageURLs.isEmpty {
                body["image_urls"] = .array(params.referenceImageURLs.map { .string($0) })
            }
            if !params.referenceVideoURLs.isEmpty {
                body["video_urls"] = .array(params.referenceVideoURLs.map { .string($0) })
            }
            if !params.referenceAudioURLs.isEmpty {
                body["audio_urls"] = .array(params.referenceAudioURLs.map { .string($0) })
            }
        } else {
            if let start = params.startFrameURL { body["image_url"] = .string(start) }
            if let end = params.endFrameURL { body["end_image_url"] = .string(end) }
        }
        if let resolution = params.resolution { body["resolution"] = .string(resolution) }
        if !params.aspectRatio.isEmpty { body["aspect_ratio"] = .string(params.aspectRatio) }
        body["duration"] = .string("\(params.duration)")
        body["generate_audio"] = .bool(params.generateAudio)
        return body
    }

    private static func klingRequest(
        base: String,
        params: VideoGenerationParams,
        proResolver: (String, VideoGenerationParams) -> String,
        proStartFrameKey: String,
        fourKStartFrameKey: String
    ) -> FalRequestDefinition {
        let endpoint: String
        let startFrameKey: String
        if params.resolution == "4k" {
            endpoint = frameOnlyEndpoint("\(base)/4k", params)
            startFrameKey = fourKStartFrameKey
        } else {
            endpoint = proResolver("\(base)/pro", params)
            startFrameKey = proStartFrameKey
        }
        return FalRequestDefinition(
            endpoint: endpoint,
            body: buildKlingBody(params, startFrameKey: startFrameKey),
            responseShape: .video
        )
    }

    private static func buildKlingBody(
        _ params: VideoGenerationParams,
        startFrameKey: String
    ) -> [String: JSONValue] {
        var body: [String: JSONValue] = ["prompt": .string(params.prompt)]
        if !params.aspectRatio.isEmpty, params.startFrameURL == nil {
            body["aspect_ratio"] = .string(params.aspectRatio)
        }
        body["generate_audio"] = .bool(params.generateAudio)
        body["duration"] = .string("\(params.duration)")
        if !params.referenceImageURLs.isEmpty {
            body["elements"] = .array(params.referenceImageURLs.map { url in
                .object([
                    "frontal_image_url": .string(url),
                    "reference_image_urls": .array([.string(url)]),
                ])
            })
            if let start = params.startFrameURL { body[startFrameKey] = .string(start) }
            if let end = params.endFrameURL { body["end_image_url"] = .string(end) }
        } else {
            if let start = params.startFrameURL { body[startFrameKey] = .string(start) }
            if let end = params.endFrameURL { body["end_image_url"] = .string(end) }
        }
        return body
    }

    private static func veoRequest(variant: String?, params: VideoGenerationParams) -> FalRequestDefinition {
        let base = "fal-ai/veo3.1"
        let prefix = variant.map { "\(base)/\($0)" } ?? base
        let endpoint: String
        if params.startFrameURL != nil, params.endFrameURL != nil {
            endpoint = "\(prefix)/first-last-frame-to-video"
        } else if params.startFrameURL != nil {
            endpoint = "\(prefix)/image-to-video"
        } else {
            endpoint = variant != nil ? prefix : base
        }

        var body: [String: JSONValue] = ["prompt": .string(params.prompt)]
        if let resolution = params.resolution { body["resolution"] = .string(resolution) }
        if !params.aspectRatio.isEmpty { body["aspect_ratio"] = .string(params.aspectRatio) }
        body["duration"] = .string("\(params.duration)s")
        body["generate_audio"] = .bool(params.generateAudio)
        if let start = params.startFrameURL, let end = params.endFrameURL {
            body["first_frame_url"] = .string(start)
            body["last_frame_url"] = .string(end)
        } else if let start = params.startFrameURL {
            body["image_url"] = .string(start)
        }
        return FalRequestDefinition(endpoint: endpoint, body: body, responseShape: .video)
    }

    private static func grokVideoRequest(params: VideoGenerationParams) -> FalRequestDefinition {
        let base = "xai/grok-imagine-video"
        let endpoint: String
        if params.startFrameURL != nil {
            endpoint = "\(base)/image-to-video"
        } else {
            endpoint = standardVideoEndpoint(base, params)
        }

        var body: [String: JSONValue] = ["prompt": .string(params.prompt)]
        if let start = params.startFrameURL {
            body["image_url"] = .string(start)
        } else if !params.referenceImageURLs.isEmpty {
            body["reference_image_urls"] = .array(params.referenceImageURLs.map { .string($0) })
        }
        if let resolution = params.resolution { body["resolution"] = .string(resolution) }
        if !params.aspectRatio.isEmpty { body["aspect_ratio"] = .string(params.aspectRatio) }
        body["duration"] = .number(Double(params.duration))
        return FalRequestDefinition(endpoint: endpoint, body: body, responseShape: .video)
    }

    // MARK: - Image request builders

    private static func imageRequest(modelID: String, params: ImageGenerationParams) throws -> FalRequestDefinition {
        switch modelID {
        case "nano-banana-pro":
            return FalRequestDefinition(
                endpoint: editEndpoint("fal-ai/nano-banana-pro", params.imageURLs),
                body: standardImageBody(params),
                responseShape: .images
            )
        case "nano-banana-2":
            return FalRequestDefinition(
                endpoint: editEndpoint("fal-ai/nano-banana-2", params.imageURLs),
                body: standardImageBody(params),
                responseShape: .images
            )
        case "grok-imagine":
            var body: [String: JSONValue] = ["prompt": .string(params.prompt)]
            if !params.imageURLs.isEmpty {
                body["image_urls"] = .array(params.imageURLs.map { .string($0) })
            } else if !params.aspectRatio.isEmpty {
                body["aspect_ratio"] = .string(params.aspectRatio)
            }
            if params.numImages > 1 {
                body["num_images"] = .number(Double(params.numImages))
            }
            return FalRequestDefinition(
                endpoint: editEndpoint("xai/grok-imagine-image", params.imageURLs),
                body: body,
                responseShape: .images
            )
        case "recraft-v4":
            var body: [String: JSONValue] = ["prompt": .string(params.prompt)]
            if !params.aspectRatio.isEmpty { body["image_size"] = .string(params.aspectRatio) }
            if params.numImages > 1 {
                body["num_images"] = .number(Double(params.numImages))
            }
            return FalRequestDefinition(
                endpoint: "fal-ai/recraft/v4/pro/text-to-image",
                body: body,
                responseShape: .images
            )
        case "gpt-image-2":
            var body: [String: JSONValue] = [
                "prompt": .string(params.prompt),
                "output_format": .string("jpeg"),
            ]
            if let resolution = params.resolution, let dims = parseWxH(resolution) {
                body["image_size"] = .object([
                    "width": .number(Double(dims.width)),
                    "height": .number(Double(dims.height)),
                ])
            }
            if let quality = params.quality, !quality.isEmpty {
                body["quality"] = .string(quality)
            }
            if !params.imageURLs.isEmpty {
                body["image_urls"] = .array(params.imageURLs.map { .string($0) })
            }
            return FalRequestDefinition(
                endpoint: editEndpoint("openai/gpt-image-2", params.imageURLs),
                body: body,
                responseShape: .images
            )
        default:
            throw GenerationProviderError.unsupported(modelID)
        }
    }

    private static func editEndpoint(_ base: String, _ imageURLs: [String]) -> String {
        imageURLs.isEmpty ? base : "\(base)/edit"
    }

    private static func standardImageBody(_ params: ImageGenerationParams) -> [String: JSONValue] {
        var body: [String: JSONValue] = [
            "prompt": .string(params.prompt),
            "output_format": .string("jpeg"),
        ]
        if !params.aspectRatio.isEmpty { body["aspect_ratio"] = .string(params.aspectRatio) }
        if let resolution = params.resolution { body["resolution"] = .string(resolution) }
        if !params.imageURLs.isEmpty {
            body["image_urls"] = .array(params.imageURLs.map { .string($0) })
        }
        if params.numImages > 1 {
            body["num_images"] = .number(Double(params.numImages))
        }
        return body
    }

    private static func parseWxH(_ value: String) -> (width: Int, height: Int)? {
        let parts = value.lowercased().split(separator: "x")
        guard parts.count == 2,
              let width = Int(parts[0]),
              let height = Int(parts[1]) else {
            return nil
        }
        return (width, height)
    }

    // MARK: - Audio request builders

    private static func audioRequest(modelID: String, params: AudioGenerationParams) throws -> FalRequestDefinition {
        switch modelID {
        case "elevenlabs-tts-v3":
            var body: [String: JSONValue] = ["text": .string(params.prompt)]
            if let voice = params.voice, !voice.isEmpty {
                body["voice"] = .string(voice)
            }
            return FalRequestDefinition(
                endpoint: "fal-ai/elevenlabs/tts/eleven-v3",
                body: body,
                responseShape: .audio
            )
        case "gemini-3.1-flash-tts":
            var body: [String: JSONValue] = ["prompt": .string(params.prompt)]
            if let voice = params.voice, !voice.isEmpty {
                body["voice"] = .string(voice)
            }
            if let style = params.styleInstructions, !style.isEmpty {
                body["style_instructions"] = .string(style)
            }
            return FalRequestDefinition(
                endpoint: "fal-ai/gemini-3.1-flash-tts",
                body: body,
                responseShape: .audio
            )
        case "minimax-music-v2.6":
            var body: [String: JSONValue] = [
                "prompt": .string(params.prompt),
                "is_instrumental": .bool(params.instrumental),
            ]
            let hasLyrics = !(params.lyrics?.isEmpty ?? true)
            if hasLyrics, let lyrics = params.lyrics {
                body["lyrics"] = .string(lyrics)
            }
            if !params.instrumental, !hasLyrics {
                body["lyrics_optimizer"] = .bool(true)
            }
            return FalRequestDefinition(
                endpoint: "fal-ai/minimax-music/v2.6",
                body: body,
                responseShape: .audio
            )
        case "elevenlabs-music":
            var body: [String: JSONValue] = [
                "prompt": .string(params.prompt),
                "force_instrumental": .bool(params.instrumental),
            ]
            if let seconds = params.durationSeconds {
                body["music_length_ms"] = .number(Double(seconds * 1000))
            }
            return FalRequestDefinition(
                endpoint: "fal-ai/elevenlabs/music",
                body: body,
                responseShape: .audio
            )
        default:
            throw GenerationProviderError.unsupported(modelID)
        }
    }

    // MARK: - Upscale request builders

    private static func upscaleRequest(
        modelID: String,
        params: UpscaleGenerationParams
    ) throws -> FalRequestDefinition {
        switch modelID {
        case "bytedance-upscaler":
            return FalRequestDefinition(
                endpoint: "fal-ai/bytedance-upscaler/upscale/video",
                body: [
                    "video_url": .string(params.sourceURL),
                    "target_resolution": .string("4k"),
                ],
                responseShape: .video
            )
        case "seedvr-upscaler":
            return FalRequestDefinition(
                endpoint: "fal-ai/seedvr/upscale/video",
                body: [
                    "video_url": .string(params.sourceURL),
                    "upscale_mode": .string("target"),
                    "target_resolution": .string("2160p"),
                ],
                responseShape: .video
            )
        case "topaz-upscaler":
            return FalRequestDefinition(
                endpoint: "fal-ai/topaz/upscale/video",
                body: [
                    "video_url": .string(params.sourceURL),
                    "upscale_factor": .number(2),
                ],
                responseShape: .video
            )
        case "seedvr-image-upscaler":
            return FalRequestDefinition(
                endpoint: "fal-ai/seedvr/upscale/image",
                body: [
                    "image_url": .string(params.sourceURL),
                    "upscale_mode": .string("target"),
                    "target_resolution": .string("2160p"),
                ],
                responseShape: .upscaledImage
            )
        case "topaz-image-upscaler":
            return FalRequestDefinition(
                endpoint: "fal-ai/topaz/upscale/image",
                body: [
                    "image_url": .string(params.sourceURL),
                    "upscale_factor": .number(2),
                ],
                responseShape: .upscaledImage
            )
        default:
            throw GenerationProviderError.unsupported(modelID)
        }
    }
}
