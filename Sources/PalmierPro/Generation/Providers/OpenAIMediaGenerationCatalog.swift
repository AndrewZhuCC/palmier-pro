import Foundation

enum OpenAIMediaGenerationCatalog {
    private static let imageModelID = "gpt-image-2"
    private static let ttsModelID = "tts-1"
    private static let ttsHDModelID = "tts-1-hd"
    private static let sora2ModelID = "sora-2"
    private static let sora2ProModelID = "sora-2-pro"

    private static let imageSizes = ["1024x1024", "1024x1536", "1536x1024"]
    private static let imageQualities = ["low", "medium", "high"]
    private static let ttsVoices = ["alloy", "echo", "fable", "onyx", "nova", "shimmer"]

    static func entries(profile: AIProviderProfile) -> [CatalogEntry] {
        let modelIDs = profile.generation?.modelIDs ?? []
        let allowed = Set(modelIDs)

        var raw: [CatalogEntry] = [
            imageEntry(profileID: profile.id),
            ttsEntry(profileID: profile.id, modelID: ttsModelID, displayName: "TTS-1"),
            ttsEntry(profileID: profile.id, modelID: ttsHDModelID, displayName: "TTS-1 HD"),
        ]

        if allowed.contains(sora2ModelID) {
            raw.append(soraEntry(profileID: profile.id, modelID: sora2ModelID, displayName: "Sora 2"))
        }
        if allowed.contains(sora2ProModelID) {
            raw.append(soraEntry(profileID: profile.id, modelID: sora2ProModelID, displayName: "Sora 2 Pro"))
        }

        guard !allowed.isEmpty else { return raw }
        return raw.filter { entry in
            guard let rawID = entry.providerModelID else { return false }
            return allowed.contains(rawID)
        }
    }

    // MARK: - Entries

    private static func imageEntry(profileID: UUID) -> CatalogEntry {
        CatalogEntry(
            id: GenerationModelIdentifier.qualify(profileID: profileID, modelID: imageModelID),
            providerProfileID: profileID,
            providerKind: .openAIMedia,
            providerModelID: imageModelID,
            kind: .image,
            displayName: "GPT Image 2",
            responseShape: .images,
            uiCapabilities: .image(ImageCaps(
                resolutions: imageSizes,
                aspectRatios: [],
                qualities: imageQualities,
                supportsImageReference: true,
                maxImages: 4
            )),
            allowedEndpoints: [],
            creditsPerSecond: nil,
            audioDiscountRate: nil,
            creditsPerImage: nil,
            qualities: imageQualities,
            audioPricing: nil,
            creditsPerSecondUpscale: nil,
            paidOnly: false
        )
    }

    private static func ttsEntry(profileID: UUID, modelID: String, displayName: String) -> CatalogEntry {
        CatalogEntry(
            id: GenerationModelIdentifier.qualify(profileID: profileID, modelID: modelID),
            providerProfileID: profileID,
            providerKind: .openAIMedia,
            providerModelID: modelID,
            kind: .audio,
            displayName: displayName,
            responseShape: .audio,
            uiCapabilities: .audio(AudioCaps(
                category: "tts",
                voices: ttsVoices,
                defaultVoice: "alloy",
                supportsLyrics: false,
                supportsInstrumental: false,
                supportsStyleInstructions: false,
                durations: nil,
                minPromptLength: 1,
                inputs: ["text"],
                promptLabel: nil,
                minSeconds: nil,
                maxSeconds: nil,
                targetLanguages: nil,
                defaultTargetLanguage: nil
            )),
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

    private static func soraEntry(profileID: UUID, modelID: String, displayName: String) -> CatalogEntry {
        CatalogEntry(
            id: GenerationModelIdentifier.qualify(profileID: profileID, modelID: modelID),
            providerProfileID: profileID,
            providerKind: .openAIMedia,
            providerModelID: modelID,
            kind: .video,
            displayName: displayName,
            responseShape: .video,
            uiCapabilities: .video(VideoCaps(
                durations: [4, 8, 12],
                resolutions: ["720p", "1080p"],
                aspectRatios: ["16:9", "9:16"],
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
                requiresSourceVideo: false,
                requiresReferenceImage: false
            )),
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
}
