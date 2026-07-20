import Foundation

extension EditSubmitter {
    enum RerunError: LocalizedError {
        case notGenerated
        case unknownModel(String)
        case missingSource
        case invalid(String)
        case unauthorized

        var errorDescription: String? {
            switch self {
            case .notGenerated: "This asset was not AI-generated"
            case .unknownModel(let id): "Model no longer available: \(id)"
            case .missingSource: "Cannot rerun: source not recorded"
            case .invalid(let msg): msg
            case .unauthorized: "Subscribe to Palmier to rerun generations"
            }
        }
    }

    @discardableResult
    static func rerun(
        asset: MediaAsset,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) throws -> String {
        guard let stored = asset.generationInput else { throw RerunError.notGenerated }
        var gen = stored
        gen.createdAt = nil
        let modelId = gen.model
        let legacyImageURLs = gen.imageURLs
        let legacyReferenceImageURLs = gen.referenceImageURLs
        let legacyReferenceVideoURLs = gen.referenceVideoURLs
        let legacyReferenceAudioURLs = gen.referenceAudioURLs
        gen.imageURLs = nil
        gen.referenceImageURLs = nil
        gen.referenceVideoURLs = nil
        gen.referenceAudioURLs = nil
        gen.providerJob = nil
        gen.backendJobId = nil
        gen.resultURLs = nil

        let assetsById = Dictionary(
            editor.mediaAssets.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        func restoreAssets(_ ids: [String]?) throws -> [MediaAsset] {
            guard let ids, !ids.isEmpty else { return [] }
            var restored: [MediaAsset] = []
            restored.reserveCapacity(ids.count)
            for id in ids {
                guard let asset = assetsById[id] else { throw RerunError.missingSource }
                restored.append(asset)
            }
            return restored
        }

        func requireAccess(paidOnly: Bool) throws {
            do {
                try GenerationAccessPolicy.validate(modelID: modelId, paidOnly: paidOnly)
            } catch {
                throw RerunError.invalid(error.localizedDescription)
            }
        }

        if let videoModel = VideoModelConfig.allModels.first(where: { $0.id == modelId }) {
            try requireAccess(paidOnly: videoModel.paidOnly)
            if let err = videoModel.validate(
                duration: gen.duration, aspectRatio: gen.aspectRatio, resolution: gen.resolution
            ) {
                throw RerunError.invalid(err)
            }

            let stableFramesOrEditRefs = try restoreAssets(gen.imageURLAssetIds)
            let stableImageRefs = try restoreAssets(gen.referenceImageAssetIds)
            let stableVideoRefs = try restoreAssets(gen.referenceVideoAssetIds)
            let stableAudioRefs = try restoreAssets(gen.referenceAudioAssetIds)
            let hasStableReferences = !stableFramesOrEditRefs.isEmpty
                || !stableImageRefs.isEmpty
                || !stableVideoRefs.isEmpty
                || !stableAudioRefs.isEmpty

            if videoModel.requiresSourceVideo {
                if hasStableReferences {
                    guard let source = stableFramesOrEditRefs.first else {
                        throw RerunError.missingSource
                    }
                    let inputAssets = VideoGenerationSubmission.InputAssets(
                        sourceVideo: source,
                        imageRefs: Array(stableFramesOrEditRefs.dropFirst())
                    )
                    if let err = inputAssets.validate(for: videoModel) {
                        throw RerunError.invalid(err)
                    }
                    return VideoGenerationSubmission.make(
                        genInput: gen,
                        model: videoModel,
                        inputAssets: inputAssets,
                        placeholderDuration: asset.duration > 0
                            ? asset.duration : Double(max(1, gen.duration)),
                        name: prefixedName("Rerun", for: asset),
                        folderId: asset.folderId,
                        generateAudio: gen.generateAudio ?? true
                    ).submit(
                        service: editor.generationService,
                        projectURL: editor.projectURL,
                        editor: editor,
                        onComplete: onComplete,
                        onFailure: onFailure
                    )
                }

                guard let source = legacyImageURLs?.first else { throw RerunError.missingSource }
                let legacyImageRefs = Array((legacyImageURLs ?? []).dropFirst())
                let params = VideoGenerationParams(
                    prompt: gen.prompt,
                    duration: gen.duration,
                    aspectRatio: gen.aspectRatio,
                    resolution: gen.resolution,
                    sourceVideoURL: source,
                    startFrameURL: nil,
                    endFrameURL: nil,
                    referenceImageURLs: legacyImageRefs,
                    generateAudio: gen.generateAudio ?? true
                )
                return editor.generationService.generate(
                    genInput: gen,
                    assetType: .video,
                    placeholderDuration: asset.duration > 0 ? asset.duration : Double(max(1, gen.duration)),
                    references: [],
                    preUploadedURLs: legacyImageURLs,
                    name: prefixedName("Rerun", for: asset),
                    folderId: asset.folderId,
                    buildParams: { _ in .video(params) },
                    fileExtension: "mp4",
                    projectURL: editor.projectURL,
                    editor: editor,
                    onComplete: onComplete,
                    onFailure: onFailure
                )
            }

            let hasLegacyReferences = legacyImageURLs?.isEmpty == false
                || legacyReferenceImageURLs?.isEmpty == false
                || legacyReferenceVideoURLs?.isEmpty == false
                || legacyReferenceAudioURLs?.isEmpty == false
            if hasStableReferences || !hasLegacyReferences {
                let inputAssets = VideoGenerationSubmission.InputAssets(
                    frames: stableFramesOrEditRefs,
                    imageRefs: stableImageRefs,
                    videoRefs: stableVideoRefs,
                    audioRefs: stableAudioRefs
                )
                if let err = inputAssets.validate(for: videoModel) {
                    throw RerunError.invalid(err)
                }
                return VideoGenerationSubmission.make(
                    genInput: gen,
                    model: videoModel,
                    inputAssets: inputAssets,
                    placeholderDuration: Double(max(1, gen.duration)),
                    name: prefixedName("Rerun", for: asset),
                    folderId: asset.folderId,
                    generateAudio: gen.generateAudio ?? true
                ).submit(
                    service: editor.generationService,
                    projectURL: editor.projectURL,
                    editor: editor,
                    onComplete: onComplete,
                    onFailure: onFailure
                )
            }

            let params = VideoGenerationParams(
                prompt: gen.prompt,
                duration: gen.duration,
                aspectRatio: gen.aspectRatio,
                resolution: gen.resolution,
                sourceVideoURL: nil,
                startFrameURL: legacyImageURLs?.first,
                endFrameURL: (legacyImageURLs?.count ?? 0) > 1 ? legacyImageURLs?[1] : nil,
                referenceImageURLs: legacyReferenceImageURLs ?? [],
                referenceVideoURLs: legacyReferenceVideoURLs ?? [],
                referenceAudioURLs: legacyReferenceAudioURLs ?? [],
                generateAudio: gen.generateAudio ?? true
            )
            let bundled = (legacyImageURLs ?? [])
                + (legacyReferenceImageURLs ?? [])
                + (legacyReferenceVideoURLs ?? [])
                + (legacyReferenceAudioURLs ?? [])
            return editor.generationService.generate(
                genInput: gen,
                assetType: .video,
                placeholderDuration: Double(max(1, gen.duration)),
                references: [],
                preUploadedURLs: bundled.isEmpty ? nil : bundled,
                name: prefixedName("Rerun", for: asset),
                folderId: asset.folderId,
                buildParams: { _ in .video(params) },
                snapshotRefs: { _, _ in },
                fileExtension: "mp4",
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
        }

        if let imageModel = ImageModelConfig.allModels.first(where: { $0.id == modelId }) {
            try requireAccess(paidOnly: imageModel.paidOnly)
            let count = min(imageModel.maxImages, max(1, gen.numImages ?? 1))
            let stableReferences = try restoreAssets(gen.imageURLAssetIds)
            let references: [MediaAsset]
            let resolvedPreUploaded: [String]?
            if !stableReferences.isEmpty {
                references = stableReferences
                resolvedPreUploaded = nil
            } else if let legacyImageURLs, !legacyImageURLs.isEmpty {
                references = []
                resolvedPreUploaded = legacyImageURLs
            } else {
                references = []
                resolvedPreUploaded = nil
            }
            let refCount = resolvedPreUploaded?.count ?? references.count
            if let err = imageModel.validate(
                aspectRatio: gen.aspectRatio, resolution: gen.resolution, quality: gen.quality,
                imageRefCount: refCount, numImages: count
            ) {
                throw RerunError.invalid(err)
            }
            return editor.generationService.generate(
                genInput: gen,
                assetType: .image,
                placeholderDuration: Defaults.imageDurationSeconds,
                references: references,
                preUploadedURLs: resolvedPreUploaded,
                name: prefixedName("Rerun", for: asset),
                numImages: count,
                folderId: asset.folderId,
                buildParams: { uploaded in
                    .image(ImageGenerationParams(
                        prompt: gen.prompt,
                        aspectRatio: gen.aspectRatio,
                        resolution: gen.resolution,
                        quality: gen.quality,
                        imageURLs: uploaded,
                        numImages: count
                    ))
                },
                fileExtension: "jpg",
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
        }

        if let audioModel = AudioModelConfig.allModels.first(where: { $0.id == modelId }) {
            try requireAccess(paidOnly: audioModel.paidOnly)
            let stableAudioSources = try restoreAssets(gen.referenceAudioAssetIds)
            let stableVideoSources = try restoreAssets(gen.referenceVideoAssetIds)
            guard stableAudioSources.count + stableVideoSources.count <= 1 else {
                throw RerunError.invalid("Cannot rerun: multiple source assets were recorded")
            }
            let stableSources = stableAudioSources + stableVideoSources
            if let source = stableSources.first, !audioModel.acceptsSource(source.type) {
                throw RerunError.invalid("Model no longer accepts \(source.type.rawValue) source media")
            }
            let legacySource = legacyImageURLs?.first
            let hasRecordedSource = !stableSources.isEmpty || legacySource != nil
            let expectsSource = audioModel.acceptsSourceMedia
                && (!audioModel.inputs.contains(.text) || hasRecordedSource)
            if expectsSource, !hasRecordedSource {
                throw RerunError.missingSource
            }

            let useLegacySource = stableSources.isEmpty && legacySource != nil
            let params = AudioGenerationParams(
                prompt: gen.prompt,
                voice: gen.voice,
                lyrics: gen.lyrics,
                styleInstructions: gen.styleInstructions,
                instrumental: gen.instrumental ?? false,
                durationSeconds: (audioModel.durations != nil || expectsSource) && gen.duration > 0
                    ? gen.duration
                    : nil,
                videoURL: useLegacySource && !audioModel.usesSourceURL ? legacySource : nil,
                sourceURL: useLegacySource && audioModel.usesSourceURL ? legacySource : nil,
                targetLanguage: gen.targetLanguage
            )
            if let err = audioModel.validate(params: params) {
                throw RerunError.invalid(err)
            }

            if !useLegacySource {
                return AudioGenerationSubmission.make(
                    genInput: gen,
                    model: audioModel,
                    params: params,
                    name: prefixedName("Rerun", for: asset),
                    folderId: asset.folderId,
                    references: stableSources
                ).submit(
                    service: editor.generationService,
                    projectURL: editor.projectURL,
                    editor: editor,
                    onComplete: onComplete,
                    onFailure: onFailure
                )
            }

            let placeholderDuration: Double = asset.duration > 0
                ? asset.duration
                : (audioModel.category == .music
                    ? Defaults.audioMusicDurationSeconds
                    : Defaults.audioTTSDurationSeconds)
            return editor.generationService.generate(
                genInput: gen,
                assetType: .audio,
                placeholderDuration: placeholderDuration,
                references: [],
                preUploadedURLs: legacyImageURLs,
                name: prefixedName("Rerun", for: asset),
                folderId: asset.folderId,
                buildParams: { _ in .audio(params) },
                fileExtension: "mp3",
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
        }

        if let upscaleModel = UpscaleModelConfig.allModels.first(where: { $0.id == modelId }) {
            try requireAccess(paidOnly: upscaleModel.paidOnly)
            let stableSources = try restoreAssets(gen.imageURLAssetIds)
            guard stableSources.count <= 1 else {
                throw RerunError.invalid("Cannot rerun: multiple upscale sources were recorded")
            }
            let legacySource = legacyImageURLs?.first
            let sourceAsset = stableSources.first
            let sourceType = sourceAsset?.type ?? asset.type
            guard upscaleModel.supportedTypes.contains(sourceType) else {
                throw RerunError.invalid("Model no longer supports \(sourceType.rawValue) upscaling")
            }
            guard sourceAsset != nil || legacySource != nil else {
                throw RerunError.missingSource
            }
            let isImage = asset.type == .image
            let useLegacySource = sourceAsset == nil
            let sourceAssetID = sourceAsset?.id
            return editor.generationService.generate(
                genInput: gen,
                assetType: asset.type,
                placeholderDuration: isImage
                    ? Defaults.imageDurationSeconds
                    : (asset.duration > 0 ? asset.duration : Double(gen.duration)),
                references: sourceAsset.map { [$0] } ?? [],
                preUploadedURLs: useLegacySource ? legacyImageURLs : nil,
                name: prefixedName("Rerun", for: asset),
                folderId: asset.folderId,
                buildParams: { uploaded in
                    .upscale(UpscaleGenerationParams(
                        sourceURL: uploaded.first ?? legacySource ?? "",
                        durationSeconds: isImage ? 1 : gen.duration
                    ))
                },
                snapshotRefs: { input, _ in
                    input.imageURLAssetIds = sourceAssetID.map { [$0] }
                },
                fileExtension: isImage ? "jpg" : "mp4",
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
        }

        throw RerunError.unknownModel(modelId)
    }
}
