import Foundation

struct OpenAIMediaGenerationProvider: GenerationProvider {
    private static let imageModelID = "gpt-image-2"
    private static let ttsModelIDs: Set<String> = ["tts-1", "tts-1-hd"]
    private static let soraModelIDs: Set<String> = ["sora-2", "sora-2-pro"]
    private static let imageSizes: Set<String> = ["1024x1024", "1024x1536", "1536x1024"]
    private static let pollIntervalSeconds: Double = 2
    private static let defaultTimeoutSeconds: Double = 1_800
    private static let timeoutRange: ClosedRange<Double> = 60...7_200
    private static let jsonMaxBytes = 8 * 1_024 * 1_024
    private static let mediaMaxBytes = 256 * 1_024 * 1_024

    let runtimeProfile: AIProviderRuntimeProfile
    private let transport: any AIHTTPTransporting

    init(
        runtimeProfile: AIProviderRuntimeProfile,
        transport: any AIHTTPTransporting = AIURLSessionTransport.shared
    ) {
        self.runtimeProfile = runtimeProfile
        self.transport = transport
    }

    func uploadReference(fileURL: URL, contentType: String) async throws -> String {
        try validateOpenAIMediaProfile()
        _ = contentType
        let path = fileURL.path(percentEncoded: false)
        let isReadable = await Task.detached(priority: .userInitiated) {
            FileManager.default.isReadableFile(atPath: path)
        }.value
        guard isReadable else {
            throw GenerationProviderError.invalidResponse("reference")
        }
        return fileURL.absoluteString
    }

    func start(request: GenerationProviderRequest) async throws -> GenerationProviderStart {
        try validateOpenAIMediaProfile()
        if let generation = runtimeProfile.profile.generation {
            try GenerationProviderModelAllowlist.validate(
                modelID: request.modelID,
                generation: generation
            )
        }
        switch request.params {
        case .image(let params):
            return try await startImage(modelID: request.modelID, params: params)
        case .audio(let params):
            return try await startAudio(modelID: request.modelID, params: params)
        case .video(let params):
            return try await startVideo(modelID: request.modelID, params: params)
        case .upscale:
            throw GenerationProviderError.unsupported("upscale")
        }
    }

    func updates(for handle: GenerationJobHandle) -> AsyncThrowingStream<GenerationProviderUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.pollUpdates(for: handle, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Image

    private func startImage(modelID: String, params: ImageGenerationParams) async throws -> GenerationProviderStart {
        guard modelID == Self.imageModelID else {
            throw GenerationProviderError.unsupported("image model")
        }

        let n = min(4, max(1, params.numImages))
        let size: String
        if let resolution = params.resolution, Self.imageSizes.contains(resolution) {
            size = resolution
        } else {
            size = "auto"
        }

        if params.imageURLs.isEmpty {
            return try await startImageGeneration(
                modelID: modelID,
                prompt: params.prompt,
                n: n,
                size: size,
                quality: params.quality
            )
        }
        return try await startImageEdit(
            modelID: modelID,
            prompt: params.prompt,
            n: n,
            size: size,
            quality: params.quality,
            imageURLs: params.imageURLs
        )
    }

    private func startImageGeneration(
        modelID: String,
        prompt: String,
        n: Int,
        size: String,
        quality: String?
    ) async throws -> GenerationProviderStart {
        var body: [String: Any] = [
            "model": modelID,
            "prompt": prompt,
            "n": n,
            "size": size,
        ]
        if let quality, !quality.isEmpty {
            body["quality"] = quality
        }

        let url = try resolveEndpoint("images/generations")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.applyProviderHeaders(runtimeProfile)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let response = try await perform(request, maxResponseBytes: Self.mediaMaxBytes)
        return try parseImageArtifacts(from: response.data)
    }

    private func startImageEdit(
        modelID: String,
        prompt: String,
        n: Int,
        size: String,
        quality: String?,
        imageURLs: [String]
    ) async throws -> GenerationProviderStart {
        let limited = Array(imageURLs.prefix(4))
        var fileParts: [(filename: String, mime: String, data: Data)] = []
        fileParts.reserveCapacity(limited.count)

        for raw in limited {
            guard let fileURL = URL(string: raw), fileURL.isFileURL else {
                throw GenerationProviderError.invalidResponse("image reference")
            }
            let data: Data
            do {
                data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: fileURL)
                }.value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw GenerationProviderError.invalidResponse("image reference")
            }
            let filename = fileURL.lastPathComponent.isEmpty ? "image.png" : fileURL.lastPathComponent
            fileParts.append((filename: filename, mime: Self.mimeType(for: filename), data: data))
        }

        var fields: [(String, String)] = [
            ("model", modelID),
            ("prompt", prompt),
            ("n", String(n)),
            ("size", size),
        ]
        if let quality, !quality.isEmpty {
            fields.append(("quality", quality))
        }

        let boundary = UUID().uuidString
        let body = Self.multipartBody(boundary: boundary, fields: fields, files: fileParts.map {
            (name: "image[]", filename: $0.filename, mime: $0.mime, data: $0.data)
        })

        let url = try resolveEndpoint("images/edits")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.applyProviderHeaders(runtimeProfile)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.httpBody = body

        let response = try await perform(request, maxResponseBytes: Self.mediaMaxBytes)
        return try parseImageArtifacts(from: response.data)
    }

    private func parseImageArtifacts(from data: Data) throws -> GenerationProviderStart {
        let json = try decodeJSON(data)
        guard case .object(let object) = json,
              case .array(let items) = object["data"] else {
            throw GenerationProviderError.invalidResponse("image data")
        }

        var artifacts: [GenerationArtifact] = []
        artifacts.reserveCapacity(items.count)
        for item in items {
            guard case .object(let entry) = item else { continue }
            if case .string(let b64) = entry["b64_json"], !b64.isEmpty {
                guard let decoded = Data(base64Encoded: b64) else {
                    throw GenerationProviderError.invalidResponse("image b64")
                }
                artifacts.append(.data(decoded, fileExtension: "png"))
                continue
            }
            if case .string(let rawURL) = entry["url"],
               let url = safeArtifactURL(rawURL) {
                artifacts.append(.remoteURL(url))
            }
        }

        guard !artifacts.isEmpty else {
            throw GenerationProviderError.invalidResponse("image data")
        }
        return .completed(artifacts)
    }

    // MARK: - Audio

    private func startAudio(modelID: String, params: AudioGenerationParams) async throws -> GenerationProviderStart {
        guard Self.ttsModelIDs.contains(modelID) else {
            throw GenerationProviderError.unsupported("audio model")
        }
        if params.sourceURL != nil || params.videoURL != nil || params.lyrics != nil || params.instrumental {
            throw GenerationProviderError.unsupported("audio source")
        }

        let voice: String
        if let raw = params.voice?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            voice = raw
        } else {
            voice = "alloy"
        }

        let body: [String: Any] = [
            "model": modelID,
            "input": params.prompt,
            "voice": voice,
            "response_format": "mp3",
        ]

        let url = try resolveEndpoint("audio/speech")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.applyProviderHeaders(runtimeProfile)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let response = try await perform(request, maxResponseBytes: Self.mediaMaxBytes)
        guard !response.data.isEmpty else {
            throw GenerationProviderError.invalidResponse("audio")
        }
        return .completed([.data(response.data, fileExtension: "mp3")])
    }

    // MARK: - Video

    private func startVideo(modelID: String, params: VideoGenerationParams) async throws -> GenerationProviderStart {
        let configuredVideoModel = runtimeProfile.profile.generation?.modelIDs.contains(modelID) == true
        guard Self.soraModelIDs.contains(modelID) || configuredVideoModel else {
            throw GenerationProviderError.unsupported("video model")
        }
        if params.sourceVideoURL != nil
            || params.startFrameURL != nil
            || params.endFrameURL != nil
            || !params.referenceImageURLs.isEmpty
            || !params.referenceVideoURLs.isEmpty
            || !params.referenceAudioURLs.isEmpty {
            throw GenerationProviderError.unsupported("video references")
        }

        var fields: [(String, String)] = [
            ("model", modelID),
            ("prompt", params.prompt),
            ("seconds", String(params.duration)),
        ]
        if let size = Self.videoSize(resolution: params.resolution, aspectRatio: params.aspectRatio) {
            fields.append(("size", size))
        }

        let boundary = UUID().uuidString
        let body = Self.multipartBody(boundary: boundary, fields: fields, files: [])

        let url = try resolveEndpoint("videos")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.applyProviderHeaders(runtimeProfile)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.httpBody = body

        let response = try await perform(request, maxResponseBytes: Self.jsonMaxBytes)
        let payload = try decodeWhitelistedVideoObject(from: response.data)
        guard let remoteID = payload.id, !remoteID.isEmpty else {
            throw GenerationProviderError.invalidResponse("video id")
        }

        let statusURL = try resolveEndpoint("videos/\(remoteID)")
        let responseURL = try resolveEndpoint("videos/\(remoteID)/content")
        let handle = GenerationJobHandle(
            providerProfileID: runtimeProfile.profile.id,
            providerKind: .openAIMedia,
            remoteID: remoteID,
            statusURL: statusURL.absoluteString,
            responseURL: responseURL.absoluteString,
            metadata: ["modelID": .string(modelID)]
        )
        return .job(handle)
    }

    private static func videoSize(resolution: String?, aspectRatio: String) -> String? {
        switch (resolution, aspectRatio) {
        case ("720p", "16:9"): return "1280x720"
        case ("720p", "9:16"): return "720x1280"
        case ("1080p", "16:9"): return "1920x1080"
        case ("1080p", "9:16"): return "1080x1920"
        default: return nil
        }
    }

    // MARK: - Polling

    private func pollUpdates(
        for handle: GenerationJobHandle,
        continuation: AsyncThrowingStream<GenerationProviderUpdate, Error>.Continuation
    ) async throws {
        try validateOpenAIMediaProfile()
        guard handle.providerProfileID == runtimeProfile.profile.id,
              handle.providerKind == .openAIMedia else {
            throw GenerationProviderError.providerMismatch
        }

        guard let statusRaw = handle.statusURL,
              let responseRaw = handle.responseURL else {
            throw GenerationProviderError.invalidResponse("handle urls")
        }
        let statusURL = try validatedCredentialURL(statusRaw)
        let responseURL = try validatedCredentialURL(responseRaw)

        let timeout = timeoutSeconds()
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            try Task.checkCancellation()
            if Date() >= deadline {
                throw GenerationProviderError.remoteFailure("timeout")
            }

            var request = URLRequest(url: statusURL)
            request.httpMethod = "GET"
            request.applyProviderHeaders(runtimeProfile)
            request.setValue("application/json", forHTTPHeaderField: "accept")

            let response = try await perform(request, maxResponseBytes: Self.jsonMaxBytes)
            let payload = try decodeWhitelistedVideoObject(from: response.data)
            let status = (payload.status ?? "").lowercased()

            switch status {
            case "queued":
                continuation.yield(.queued)
            case "in_progress", "running":
                continuation.yield(.running(progress: Self.normalizeProgress(payload.progress)))
            case "completed":
                let data = try await fetchVideoContent(from: responseURL)
                continuation.yield(.succeeded([.data(data, fileExtension: "mp4")]))
                return
            case "failed", "cancelled":
                continuation.yield(.failed(code: status))
                return
            default:
                throw GenerationProviderError.invalidResponse("status")
            }

            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(Self.pollIntervalSeconds))
        }
    }

    private func fetchVideoContent(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.applyProviderHeaders(runtimeProfile)
        let response = try await perform(request, maxResponseBytes: Self.mediaMaxBytes)
        guard !response.data.isEmpty else {
            throw GenerationProviderError.invalidResponse("video content")
        }
        return response.data
    }

    private static func normalizeProgress(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        if value >= 0, value <= 1 { return value }
        if value > 1, value <= 100 { return value / 100 }
        return nil
    }

    // MARK: - Transport

    private func perform(
        _ request: URLRequest,
        maxResponseBytes: Int
    ) async throws -> AIHTTPDataResponse {
        let response: AIHTTPDataResponse
        do {
            response = try await transport.data(for: request, maxResponseBytes: maxResponseBytes)
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
        return response
    }

    private func decodeJSON(_ data: Data) throws -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw GenerationProviderError.invalidResponse("json")
        }
    }

    private struct VideoStatusPayload: Sendable {
        let id: String?
        let status: String?
        let progress: Double?
    }

    private func decodeWhitelistedVideoObject(from data: Data) throws -> VideoStatusPayload {
        let json = try decodeJSON(data)
        guard case .object(let object) = json else {
            throw GenerationProviderError.invalidResponse("video")
        }
        let id: String?
        if case .string(let value) = object["id"] {
            id = value
        } else {
            id = nil
        }
        let status: String?
        if case .string(let value) = object["status"] {
            status = value
        } else {
            status = nil
        }
        let progress: Double?
        if case .number(let value) = object["progress"] {
            progress = value
        } else {
            progress = nil
        }
        return VideoStatusPayload(id: id, status: status, progress: progress)
    }

    private func resolveEndpoint(_ path: String) throws -> URL {
        try AIProviderEndpoint.resolve(
            baseURL: runtimeProfile.profile.baseURL,
            endpointPath: path,
            allowInsecureHTTP: runtimeProfile.profile.allowInsecureHTTP
        )
    }

    private func validatedCredentialURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              let base = try? AIProviderEndpoint.normalizedBaseURL(
                  runtimeProfile.profile.baseURL,
                  allowInsecureHTTP: runtimeProfile.profile.allowInsecureHTTP
              ) else {
            throw GenerationProviderError.invalidResponse("handle url")
        }
        if scheme == "http",
           !AIProviderEndpoint.isLoopbackHost(host),
           !runtimeProfile.profile.allowInsecureHTTP {
            throw GenerationProviderError.invalidResponse("handle url")
        }
        if !AIProviderEndpoint.sameOrigin(url, base),
           !runtimeProfile.profile.allowCredentialRedirects {
            throw GenerationProviderError.invalidResponse("handle url")
        }
        return url
    }

    private func safeArtifactURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host else {
            return nil
        }
        if scheme == "http",
           !AIProviderEndpoint.isLoopbackHost(host),
           !runtimeProfile.profile.allowInsecureHTTP {
            return nil
        }
        return url
    }

    private func timeoutSeconds() -> Double {
        let options = runtimeProfile.profile.generation?.options ?? [:]
        let raw: Double
        if case .number(let value) = options["timeoutSeconds"], value.isFinite {
            raw = value
        } else {
            raw = Self.defaultTimeoutSeconds
        }
        return min(Self.timeoutRange.upperBound, max(Self.timeoutRange.lowerBound, raw))
    }

    private func validateOpenAIMediaProfile() throws {
        guard runtimeProfile.profile.generation != nil else {
            throw GenerationProviderError.missingGenerationService
        }
        guard runtimeProfile.profile.generation?.providerKind == .openAIMedia else {
            throw GenerationProviderError.providerMismatch
        }
    }

    // MARK: - Multipart

    private static func multipartBody(
        boundary: String,
        fields: [(String, String)],
        files: [(name: String, filename: String, mime: String, data: Data)]
    ) -> Data {
        var body = Data()
        let crlf = "\r\n"

        for (name, value) in fields {
            body.append(Data("--\(boundary)\(crlf)".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\(crlf)".utf8))
            body.append(Data(crlf.utf8))
            body.append(Data("\(value)\(crlf)".utf8))
        }

        for file in files {
            body.append(Data("--\(boundary)\(crlf)".utf8))
            body.append(Data(
                "Content-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\"\(crlf)".utf8
            ))
            body.append(Data("Content-Type: \(file.mime)\(crlf)".utf8))
            body.append(Data(crlf.utf8))
            body.append(file.data)
            body.append(Data(crlf.utf8))
        }

        body.append(Data("--\(boundary)--\(crlf)".utf8))
        return body
    }

    private static func mimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        default: return "application/octet-stream"
        }
    }
}
