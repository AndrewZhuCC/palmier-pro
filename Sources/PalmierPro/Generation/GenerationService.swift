import Foundation

/// Used by replace-clip callbacks so only the
/// first successful asset of an N-image generation swaps the clip
@MainActor
final class FirstOnlyFlag {
    private var fired = false
    func fire() -> Bool {
        guard !fired else { return false }
        fired = true
        return true
    }
}

@MainActor
final class GenerationService {

    private static let uploadCacheTTL: TimeInterval = 6 * 24 * 60 * 60
    private var resumedGenerationJobs: Set<String> = []

    private struct PreparedReferences {
        let uploaded: [String]
        let tempFiles: [URL]
    }

    private struct ProviderContext {
        let profileID: UUID
        let providerKind: GenerationProviderKind
        let modelID: String
        let provider: any GenerationProvider
    }

    @discardableResult
    func generate(
        genInput: GenerationInput,
        assetType: ClipType,
        placeholderDuration: Double,
        references: [MediaAsset] = [],
        trimmedSourceOverride: TrimmedSource? = nil,
        preUploadedURLs: [String]? = nil,
        name: String? = nil,
        numImages: Int = 1,
        folderId: String? = nil,
        buildParams: @escaping ([String]) -> BackendGenerationParams,
        snapshotRefs: (@Sendable (inout GenerationInput, [String]) -> Void)? = nil,
        preprocessRef: (@Sendable (Int, MediaAsset) async throws -> URL?)? = nil,
        fileExtension: String,
        projectURL: URL?,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) -> String {
        let count = max(1, min(4, numImages))
        let baseName = name ?? String(genInput.prompt.prefix(30))

        let resolvedFolderId = folderId.flatMap { id in
            editor.folder(id: id) != nil ? id : nil
        }
        var placeholders: [MediaAsset] = []
        let destDir = Self.destinationDirectory(for: projectURL)

        for outputIndex in 0..<count {
            var placeholderInput = genInput
            placeholderInput.outputIndex = outputIndex
            let placeholder = createPlaceholder(
                type: assetType,
                name: baseName,
                duration: placeholderDuration,
                genInput: placeholderInput,
                folderId: resolvedFolderId,
                destDir: destDir,
                fileExtension: fileExtension,
                editor: editor
            )
            placeholders.append(placeholder)
        }
        let primaryId = placeholders[0].id

        Task { @MainActor in
            do {
                let context = try await self.providerContext(for: genInput)
                let prepared = try await self.prepareReferences(
                    references: references,
                    trimmedSourceOverride: trimmedSourceOverride,
                    preUploadedURLs: preUploadedURLs,
                    preprocessRef: preprocessRef,
                    provider: context.provider,
                    providerProfileID: context.profileID
                )
                let uploaded = prepared.uploaded

                var finalGenInput = genInput
                if let snapshotRefs {
                    snapshotRefs(&finalGenInput, uploaded)
                } else {
                    finalGenInput.imageURLs = uploaded.isEmpty ? nil : uploaded
                }
                Self.scrubTransientReferenceURLs(&finalGenInput)
                finalGenInput.providerProfileID = context.profileID
                finalGenInput.providerKind = context.providerKind
                finalGenInput.providerJob = nil
                finalGenInput.backendJobId = nil
                finalGenInput.resultURLs = nil
                if finalGenInput.createdAt == nil {
                    finalGenInput.createdAt = Date()
                }
                for (outputIndex, placeholder) in placeholders.enumerated() {
                    var storedInput = finalGenInput
                    storedInput.outputIndex = outputIndex
                    updateGenerationMetadata(placeholder, editor: editor) { input in
                        input = storedInput
                    }
                }

                let params = buildParams(uploaded)
                await Self.cleanupTempFiles(prepared.tempFiles)

                await self.runJob(
                    placeholders: placeholders,
                    params: params,
                    genInput: finalGenInput,
                    context: context,
                    editor: editor,
                    onComplete: onComplete,
                    onFailure: onFailure
                )
            } catch {
                let message = error.localizedDescription
                Log.generation.error("generation preparation failed model=\(genInput.model) error=\(message)")
                for placeholder in placeholders {
                    updateGenerationMetadata(placeholder, editor: editor, status: .failed(message))
                }
                onFailure?()
            }
        }

        return primaryId
    }

    func uploadReference(
        modelID: String,
        fileURL: URL,
        contentType: String
    ) async throws -> String {
        let input = GenerationInput(
            prompt: "",
            model: modelID,
            duration: 0,
            aspectRatio: "",
            resolution: nil
        )
        let context = try await providerContext(for: input)
        return try await context.provider.uploadReference(
            fileURL: fileURL,
            contentType: contentType
        )
    }

    private func prepareReferences(
        references: [MediaAsset],
        trimmedSourceOverride: TrimmedSource?,
        preUploadedURLs: [String]?,
        preprocessRef: (@Sendable (Int, MediaAsset) async throws -> URL?)?,
        provider: any GenerationProvider,
        providerProfileID: UUID
    ) async throws -> PreparedReferences {
        if let preUploadedURLs, !preUploadedURLs.isEmpty {
            return PreparedReferences(uploaded: preUploadedURLs, tempFiles: [])
        }

        var tempFiles: [URL] = []
        do {
            var urlsToUpload = references.map(\.url)
            let refTypes = references.map(\.type)
            if let trim = trimmedSourceOverride, trim.hasTrim, !urlsToUpload.isEmpty {
                Log.generation.notice("using trimmed source: frames \(trim.trimStartFrame)+\(trim.sourceFramesConsumed) of \(urlsToUpload[0].lastPathComponent)")
                let extracted = try await VideoTrimExtractor.extract(trim)
                urlsToUpload[0] = extracted
                tempFiles.append(extracted)
            }
            if let preprocessRef, !references.isEmpty {
                let rewrites = try await preprocessedReferenceURLs(references: references, preprocessRef: preprocessRef)
                for (i, rewritten) in rewrites {
                    guard let rewritten else { continue }
                    urlsToUpload[i] = rewritten
                    tempFiles.append(rewritten)
                }
            }
            let uploaded = try await uploadReferences(
                at: urlsToUpload,
                types: refTypes,
                cacheKeys: uploadCacheKeys(
                    references: references,
                    trimmedFirstReference: trimmedSourceOverride?.hasTrim == true,
                    hasPreprocess: preprocessRef != nil
                ),
                provider: provider,
                providerProfileID: providerProfileID
            )
            return PreparedReferences(uploaded: uploaded, tempFiles: tempFiles)
        } catch {
            await Self.cleanupTempFiles(tempFiles)
            throw error
        }
    }

    private func preprocessedReferenceURLs(
        references: [MediaAsset],
        preprocessRef: @escaping @Sendable (Int, MediaAsset) async throws -> URL?
    ) async throws -> [(Int, URL?)] {
        try await withThrowingTaskGroup(of: (Int, URL?).self) { group in
            for (i, asset) in references.enumerated() {
                group.addTask { (i, try await preprocessRef(i, asset)) }
            }
            var results: [(Int, URL?)] = []
            for try await result in group { results.append(result) }
            return results
        }
    }

    private func uploadCacheKeys(
        references: [MediaAsset],
        trimmedFirstReference: Bool,
        hasPreprocess: Bool
    ) -> [MediaAsset?] {
        references.enumerated().map { index, asset in
            if hasPreprocess { return nil }
            if index == 0 && trimmedFirstReference { return nil }
            return asset
        }
    }

    private nonisolated static func cleanupTempFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        await Task.detached(priority: .utility) {
            for url in urls {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    // Best-effort cleanup: the project commit path may already have moved the file.
                }
            }
        }.value
    }

    /// Resolves provider context for new submissions/uploads from the live model registry only.
    /// Provider-job resume must not call this; it uses the persisted job handle directly.
    private func providerContext(for input: GenerationInput) async throws -> ProviderContext {
        guard let entry = ModelRegistry.entry(for: input.model) else {
            throw GenerationProviderError.unsupported("model '\(input.model)'")
        }
        guard let profileID = entry.providerProfileID,
              let providerKind = entry.providerKind,
              let providerModelID = entry.providerModelID else {
            throw GenerationProviderError.unsupported("model '\(input.model)'")
        }
        try GenerationAccessPolicy.validate(modelID: input.model, paidOnly: entry.paidOnly)

        guard let profile = AIProviderStore.shared.profile(id: profileID),
              profile.enabled,
              let configuration = profile.generation else {
            throw GenerationProviderError.missingGenerationService
        }
        guard providerKind == configuration.providerKind else {
            throw GenerationProviderError.providerMismatch
        }
        if !configuration.modelIDs.isEmpty,
           !configuration.modelIDs.contains(providerModelID) {
            throw GenerationProviderError.unsupported("model '\(providerModelID)'")
        }

        let runtime = try await AIProviderStore.shared.runtimeProfile(id: profileID)
        let provider = try GenerationProviderFactory.make(runtimeProfile: runtime)
        return ProviderContext(
            profileID: profileID,
            providerKind: providerKind,
            modelID: providerModelID,
            provider: provider
        )
    }

    /// Uploaded reference URLs may expire or contain signed query credentials.
    /// Persist stable media asset IDs instead and re-upload on rerun.
    private static func scrubTransientReferenceURLs(_ input: inout GenerationInput) {
        input.imageURLs = nil
        input.referenceImageURLs = nil
        input.referenceVideoURLs = nil
        input.referenceAudioURLs = nil
    }

    // MARK: - Shared

    private func createPlaceholder(
        type: ClipType,
        name: String,
        duration: Double,
        genInput: GenerationInput,
        folderId: String?,
        destDir: URL,
        fileExtension: String,
        editor: EditorViewModel
    ) -> MediaAsset {
        let id = UUID().uuidString
        let destURL = destDir.appendingPathComponent("gen-\(id.prefix(8)).\(fileExtension)")
        let placeholder = MediaAsset(
            id: id,
            url: destURL,
            type: type,
            name: name,
            duration: duration,
            generationInput: genInput
        )
        placeholder.generationStatus = .preparing
        placeholder.folderId = folderId
        editor.importMediaAsset(placeholder)
        return placeholder
    }

    private static func destinationDirectory(for projectURL: URL?) -> URL {
        if let projectURL {
            return projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
    }

    private static func isArtifactURLAllowed(_ url: URL, input: GenerationInput?) -> Bool {
        guard url.user == nil,
              url.password == nil,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host else {
            return false
        }
        if scheme == "https" || AIProviderEndpoint.isLoopbackHost(host) {
            return true
        }
        guard let profileID = input?.providerProfileID,
              let profile = AIProviderStore.shared.profile(id: profileID) else {
            return false
        }
        return profile.allowInsecureHTTP
    }

    @discardableResult
    private func downloadAndFinalize(asset: MediaAsset, remoteURL: URL, editor: EditorViewModel) async -> Bool {
        guard Self.isArtifactURLAllowed(remoteURL, input: asset.generationInput) else {
            updateGenerationMetadata(asset, editor: editor, status: .failed("Invalid result URL"))
            return false
        }
        asset.pendingDownloadURL = remoteURL
        if asset.generationStatus != .downloading {
            updateGenerationMetadata(asset, editor: editor, status: .downloading)
        }
        var tempURL: URL?
        do {
            let (downloadedURL, _) = try await URLSession.shared.download(from: remoteURL)
            tempURL = downloadedURL
            let finalized = try await commitAndFinalize(
                asset: asset,
                stagedURL: downloadedURL,
                suggestedExtension: remoteURL.pathExtension,
                editor: editor
            )
            await Self.cleanupTempFiles([downloadedURL])
            return finalized
        } catch {
            if let tempURL {
                await Self.cleanupTempFiles([tempURL])
            }
            let message = error.localizedDescription
            Log.generation.error("download failed host=\(remoteURL.host ?? "unknown") error=\(message)")
            asset.pendingDownloadURL = remoteURL
            updateGenerationMetadata(asset, editor: editor, status: .failed(message))
            return false
        }
    }

    @discardableResult
    private func writeAndFinalize(
        asset: MediaAsset,
        data: Data,
        fileExtension: String,
        editor: EditorViewModel
    ) async -> Bool {
        if asset.generationStatus != .downloading {
            updateGenerationMetadata(asset, editor: editor, status: .downloading)
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("generation-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        do {
            try await Task.detached(priority: .userInitiated) {
                try data.write(to: tempURL, options: .atomic)
            }.value
            let finalized = try await commitAndFinalize(
                asset: asset,
                stagedURL: tempURL,
                suggestedExtension: fileExtension,
                editor: editor
            )
            await Self.cleanupTempFiles([tempURL])
            return finalized
        } catch {
            await Self.cleanupTempFiles([tempURL])
            let message = error.localizedDescription
            Log.generation.error("inline generation output write failed error=\(message)")
            updateGenerationMetadata(asset, editor: editor, status: .failed(message))
            return false
        }
    }

    private func commitAndFinalize(
        asset: MediaAsset,
        stagedURL: URL,
        suggestedExtension: String,
        editor: EditorViewModel
    ) async throws -> Bool {
        let normalizedExtension = suggestedExtension.lowercased()
        if !normalizedExtension.isEmpty,
           normalizedExtension != asset.url.pathExtension.lowercased(),
           ClipType(fileExtension: normalizedExtension) != nil {
            asset.url = asset.url.deletingPathExtension().appendingPathExtension(normalizedExtension)
        }
        asset.url = try await editor.commitStagedProjectMedia(
            stagedURL,
            filename: asset.url.lastPathComponent
        )
        editor.importMediaAsset(asset, skipAppend: true)
        let finalized = await editor.finalizeImportedAsset(asset)
        if finalized {
            asset.pendingDownloadURL = nil
            if var input = asset.generationInput {
                input.providerJob = nil
                input.backendJobId = nil
                input.resultURLs = nil
                asset.generationInput = input
            }
            editor.updateManifestMetadata(for: [asset])
            editor.appendGenerationLog(for: asset)
        }
        return finalized
    }

    func retryDownload(asset: MediaAsset, editor: EditorViewModel) {
        guard let remoteURL = asset.pendingDownloadURL else { return }
        Task { @MainActor in
            _ = await downloadAndFinalize(asset: asset, remoteURL: remoteURL, editor: editor)
            editor.onProjectCheckpointRequired?()
        }
    }

    func resumePendingGenerations(editor: EditorViewModel) {
        func sorted(_ assets: [MediaAsset]) -> [MediaAsset] {
            assets.sorted {
                let left = $0.generationInput?.outputIndex ?? 0
                let right = $1.generationInput?.outputIndex ?? 0
                return left < right
            }
        }

        let pending = editor.mediaAssets.filter(\.isRecoveringGeneration)

        for asset in pending {
            guard let input = asset.generationInput,
                  let resultURLs = input.resultURLs,
                  !resultURLs.isEmpty else { continue }
            let key = "result:\(asset.id)"
            guard !resumedGenerationJobs.contains(key) else { continue }
            resumedGenerationJobs.insert(key)
            let outputIndex = input.outputIndex ?? 0
            Task { @MainActor [weak self, weak editor] in
                defer { self?.resumedGenerationJobs.remove(key) }
                guard let self, let editor else { return }
                guard resultURLs.indices.contains(outputIndex),
                      let remoteURL = URL(string: resultURLs[outputIndex]),
                      Self.isArtifactURLAllowed(remoteURL, input: input) else {
                    self.updateGenerationMetadata(
                        asset,
                        editor: editor,
                        status: .failed("Invalid result URL")
                    )
                    editor.onProjectCheckpointRequired?()
                    return
                }
                _ = await self.downloadAndFinalize(asset: asset, remoteURL: remoteURL, editor: editor)
                editor.onProjectCheckpointRequired?()
            }
        }

        let recoverable = pending.compactMap { asset -> (key: String, handle: GenerationJobHandle, asset: MediaAsset)? in
            guard let input = asset.generationInput else { return nil }
            if let resultURLs = input.resultURLs, !resultURLs.isEmpty { return nil }
            let handle: GenerationJobHandle
            if let providerJob = input.providerJob {
                handle = providerJob
            } else if let backendJobID = input.backendJobId, !backendJobID.isEmpty {
                handle = GenerationJobHandle(
                    providerProfileID: AIProviderProfile.palmierManagedID,
                    providerKind: .palmierManaged,
                    remoteID: backendJobID
                )
            } else {
                return nil
            }
            let key = "\(handle.providerProfileID.uuidString):\(handle.remoteID)"
            return (key, handle, asset)
        }
        let grouped = Dictionary(grouping: recoverable, by: \.key)

        for (key, group) in grouped where !resumedGenerationJobs.contains(key) {
            guard let handle = group.first?.handle else { continue }
            let placeholders = sorted(group.map(\.asset))
            resumedGenerationJobs.insert(key)
            Task { @MainActor [weak self, weak editor] in
                defer { self?.resumedGenerationJobs.remove(key) }
                guard let self, let editor else { return }
                do {
                    let runtime = try await AIProviderStore.shared.runtimeProfile(
                        id: handle.providerProfileID
                    )
                    let provider = try GenerationProviderFactory.make(runtimeProfile: runtime)
                    await self.monitorProviderJob(
                        provider: provider,
                        handle: handle,
                        placeholders: placeholders,
                        editor: editor,
                        onComplete: nil,
                        onFailure: nil
                    )
                } catch {
                    let message = error.localizedDescription
                    for placeholder in placeholders {
                        self.updateGenerationMetadata(
                            placeholder,
                            editor: editor,
                            status: .failed(message)
                        )
                    }
                    editor.onProjectCheckpointRequired?()
                }
            }
        }
    }

    private func updateGenerationMetadata(
        _ asset: MediaAsset,
        editor: EditorViewModel,
        status: MediaAsset.GenerationStatus? = nil,
        mutateInput: ((inout GenerationInput) -> Void)? = nil
    ) {
        if let status {
            asset.generationStatus = status
        }
        if let mutateInput, var input = asset.generationInput {
            mutateInput(&input)
            asset.generationInput = input
        }
        editor.updateManifestMetadata(for: [asset])
    }

    /// Uploads each reference and returns the hosted URLs.
    private func uploadReferences(
        at urls: [URL],
        types: [ClipType],
        cacheKeys: [MediaAsset?],
        provider: any GenerationProvider,
        providerProfileID: UUID
    ) async throws -> [String] {
        guard !urls.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (i, url) in urls.enumerated() {
                let type = types.indices.contains(i) ? types[i] : .image
                let cacheKey = cacheKeys.indices.contains(i) ? cacheKeys[i] : nil
                if let cacheKey, let hit = cacheKey.freshRemoteURL(for: providerProfileID) {
                    group.addTask { (i, hit) }
                    continue
                }
                let contentType = Self.contentType(for: url, fallback: type)
                group.addTask {
                    let uploaded = try await provider.uploadReference(
                        fileURL: url,
                        contentType: contentType
                    )
                    if let cacheKey {
                        await Self.recordUploadCache(
                            asset: cacheKey,
                            url: uploaded,
                            providerProfileID: providerProfileID
                        )
                    }
                    return (i, uploaded)
                }
            }
            var results = [(Int, String)]()
            for try await r in group { results.append(r) }
            return results.sorted(by: { $0.0 < $1.0 }).map(\.1)
        }
    }

    @MainActor
    private static func recordUploadCache(
        asset: MediaAsset,
        url: String,
        providerProfileID: UUID
    ) {
        guard let parsed = URL(string: url),
              parsed.scheme == "https" || parsed.scheme == "http",
              parsed.user == nil,
              parsed.password == nil,
              parsed.query == nil,
              parsed.fragment == nil else {
            return
        }
        asset.cachedRemoteURL = url
        asset.cachedRemoteURLExpiresAt = Date().addingTimeInterval(uploadCacheTTL)
        asset.cachedRemoteProviderProfileID = providerProfileID
    }

    private static func contentType(for url: URL, fallback: ClipType) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "gif": return "image/gif"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "aiff", "aif", "aifc": return "audio/aiff"
        case "caf": return "audio/x-caf"
        case "flac": return "audio/flac"
        default:
            switch fallback {
            case .image: return "image/jpeg"
            case .video: return "video/mp4"
            case .audio: return "audio/mpeg"
            case .text: return "application/octet-stream"
            case .lottie: return "application/json"
            case .sequence: return "video/mp4"
            }
        }
    }

    // MARK: - Job execution

    private func runJob(
        placeholders: [MediaAsset],
        params: BackendGenerationParams,
        genInput: GenerationInput,
        context: ProviderContext,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        let runID = String(UUID().uuidString.prefix(8))
        Log.generation.notice("run \(runID) start model=\(genInput.model) placeholders=\(placeholders.count)")
        defer { Log.generation.notice("run \(runID) settled") }

        let start: GenerationProviderStart
        do {
            start = try await context.provider.start(request: GenerationProviderRequest(
                modelID: context.modelID,
                params: params,
                projectID: editor.projectId
            ))
        } catch {
            let message = error.localizedDescription
            Log.generation.error("generation submit failed model=\(genInput.model) error=\(message)")
            for placeholder in placeholders {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed(message))
            }
            onFailure?()
            return
        }

        switch start {
        case .completed(let artifacts):
            await finalizeSuccess(
                artifacts: artifacts,
                placeholders: placeholders,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )

        case .job(let handle):
            for placeholder in placeholders {
                updateGenerationMetadata(placeholder, editor: editor, status: .generating) { input in
                    input.providerProfileID = handle.providerProfileID
                    input.providerKind = handle.providerKind
                    input.providerJob = handle
                    input.backendJobId = handle.providerKind == .palmierManaged ? handle.remoteID : nil
                }
            }
            editor.onProjectCheckpointRequired?()
            await monitorProviderJob(
                provider: context.provider,
                handle: handle,
                placeholders: placeholders,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
        }
    }

    private func monitorProviderJob(
        provider: any GenerationProvider,
        handle: GenerationJobHandle,
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        do {
            for try await update in provider.updates(for: handle) {
                switch update {
                case .queued, .running:
                    if updateProviderJobMetadata(placeholders, handle: handle, editor: editor) {
                        editor.onProjectCheckpointRequired?()
                    }

                case .succeeded(let artifacts):
                    _ = updateProviderJobMetadata(placeholders, handle: handle, editor: editor)
                    await finalizeSuccess(
                        artifacts: artifacts,
                        placeholders: placeholders,
                        editor: editor,
                        onComplete: onComplete,
                        onFailure: onFailure
                    )
                    return

                case .failed(let code):
                    let message = GenerationProviderError.remoteFailure(code).localizedDescription
                    Log.generation.error("generation job failed provider=\(handle.providerKind.rawValue) code=\(code)")
                    for placeholder in placeholders {
                        updateGenerationMetadata(placeholder, editor: editor, status: .failed(message)) { input in
                            input.providerJob = handle
                        }
                    }
                    editor.onProjectCheckpointRequired?()
                    onFailure?()
                    return
                }
            }
        } catch is CancellationError {
            return
        } catch {
            let message = error.localizedDescription
            Log.generation.error("generation monitor failed provider=\(handle.providerKind.rawValue) error=\(message)")
            for placeholder in placeholders {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed(message)) { input in
                    input.providerJob = handle
                }
            }
            editor.onProjectCheckpointRequired?()
            onFailure?()
            return
        }

        let persisted = placeholders.compactMap(\.generationInput?.resultURLs).first ?? []
        var recoveredArtifacts: [GenerationArtifact] = []
        recoveredArtifacts.reserveCapacity(persisted.count)
        for value in persisted {
            guard !value.isEmpty,
                  let url = URL(string: value),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return }
            recoveredArtifacts.append(.remoteURL(url))
        }
        guard !recoveredArtifacts.isEmpty else { return }
        await finalizeSuccess(
            artifacts: recoveredArtifacts,
            placeholders: placeholders,
            editor: editor,
            onComplete: onComplete,
            onFailure: onFailure
        )
    }

    @discardableResult
    private func updateProviderJobMetadata(
        _ placeholders: [MediaAsset],
        handle: GenerationJobHandle,
        editor: EditorViewModel
    ) -> Bool {
        var changed = false
        for placeholder in placeholders {
            guard placeholder.generationStatus != .downloading,
                  placeholder.generationStatus != .generating ||
                  placeholder.generationInput?.providerJob != handle else {
                continue
            }
            updateGenerationMetadata(placeholder, editor: editor, status: .generating) { input in
                input.providerProfileID = handle.providerProfileID
                input.providerKind = handle.providerKind
                input.providerJob = handle
                input.backendJobId = handle.providerKind == .palmierManaged ? handle.remoteID : nil
            }
            changed = true
        }
        return changed
    }

    private func finalizeSuccess(
        artifacts: [GenerationArtifact],
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        guard !artifacts.isEmpty else {
            Log.generation.error("generation succeeded with no artifacts")
            for placeholder in placeholders {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed("No output in response"))
            }
            onFailure?()
            return
        }
        if artifacts.count < placeholders.count {
            Log.generation.notice("provider returned \(artifacts.count) output(s) for \(placeholders.count) placeholder(s); marking extras as failed")
        }

        // Empty markers preserve output indices when a provider mixes inline and remote artifacts.
        let persistedURLs = artifacts.map { artifact -> String in
            guard case .remoteURL(let url) = artifact else { return "" }
            return url.absoluteString
        }
        var outputs: [(placeholder: MediaAsset, artifact: GenerationArtifact)] = []
        outputs.reserveCapacity(placeholders.count)
        for (index, placeholder) in placeholders.enumerated() {
            let outputIndex = placeholder.generationInput?.outputIndex ?? index
            guard artifacts.indices.contains(outputIndex) else {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed("No output for placeholder"))
                continue
            }

            let artifact = artifacts[outputIndex]
            if case .remoteURL(let remoteURL) = artifact,
               !Self.isArtifactURLAllowed(remoteURL, input: placeholder.generationInput) {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed("Invalid result URL"))
                continue
            }
            updateGenerationMetadata(placeholder, editor: editor, status: .downloading) { input in
                if case .remoteURL = artifact {
                    input.resultURLs = persistedURLs
                } else {
                    input.resultURLs = nil
                }
            }
            outputs.append((placeholder, artifact))
        }
        editor.onProjectCheckpointRequired?()

        var finalized: [MediaAsset] = []
        for output in outputs {
            let didFinalize: Bool
            switch output.artifact {
            case .remoteURL(let remoteURL):
                didFinalize = await downloadAndFinalize(
                    asset: output.placeholder,
                    remoteURL: remoteURL,
                    editor: editor
                )
            case .data(let data, let fileExtension):
                didFinalize = await writeAndFinalize(
                    asset: output.placeholder,
                    data: data,
                    fileExtension: fileExtension,
                    editor: editor
                )
            }
            if didFinalize {
                onComplete?(output.placeholder)
                finalized.append(output.placeholder)
            }
        }

        if let first = finalized.first {
            AppNotifications.generationComplete(
                assetId: first.id,
                projectURL: editor.projectURL,
                assetName: first.name,
                assetType: first.type,
                count: finalized.count
            )
        } else {
            onFailure?()
        }
    }

}
