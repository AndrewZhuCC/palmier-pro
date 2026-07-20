import Foundation
@preconcurrency import FalClient

struct FalGenerationProvider: GenerationProvider {
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
        try validateFalProfile()
        guard let base = try? AIProviderEndpoint.normalizedBaseURL(
            runtimeProfile.profile.baseURL,
            allowInsecureHTTP: runtimeProfile.profile.allowInsecureHTTP
        ), base.host?.lowercased() == "queue.fal.run" else {
            throw GenerationProviderError.unsupported(
                "fal.ai SDK uploads require the official queue.fal.run base URL"
            )
        }
        _ = contentType
        guard let key = runtimeProfile.primaryCredential, !key.isEmpty else {
            throw GenerationProviderError.missingCredential
        }

        let data: Data
        do {
            data = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: fileURL)
            }.value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GenerationProviderError.transport(error.localizedDescription)
        }

        let fileType = FileType.inferred(from: fileURL)
        do {
            let client = FalClient.withCredentials(.keyPair(key))
            return try await client.storage.upload(data: data, ofType: fileType)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GenerationProviderError.transport(error.localizedDescription)
        }
    }

    func start(request: GenerationProviderRequest) async throws -> GenerationProviderStart {
        try validateFalProfile()
        if let generation = runtimeProfile.profile.generation {
            try GenerationProviderModelAllowlist.validate(
                modelID: request.modelID,
                generation: generation
            )
        }
        let definition = try FalGenerationCatalog.request(
            modelID: request.modelID,
            params: request.params
        )

        let profile = runtimeProfile.profile
        let url = try AIProviderEndpoint.resolve(
            baseURL: profile.baseURL,
            endpointPath: definition.endpoint,
            allowInsecureHTTP: profile.allowInsecureHTTP
        )

        let foundationBody = definition.body.mapValues(\.foundationValue)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.applyProviderHeaders(runtimeProfile)
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "accept")
        do {
            urlRequest.httpBody = try JSONSerialization.data(
                withJSONObject: foundationBody,
                options: [.sortedKeys]
            )
        } catch {
            throw GenerationProviderError.invalidResponse("body")
        }

        let response = try await perform(urlRequest)
        let json = try decodeJSON(response.data)
        return try parseStartResponse(
            json,
            modelID: request.modelID,
            responseShape: definition.responseShape
        )
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

    // MARK: - Polling

    private func pollUpdates(
        for handle: GenerationJobHandle,
        continuation: AsyncThrowingStream<GenerationProviderUpdate, Error>.Continuation
    ) async throws {
        try validateFalProfile()
        guard handle.providerProfileID == runtimeProfile.profile.id,
              handle.providerKind == .falQueue else {
            throw GenerationProviderError.providerMismatch
        }

        guard let statusRaw = handle.statusURL, !statusRaw.isEmpty,
              let statusURL = resolveProviderURL(statusRaw) else {
            throw GenerationProviderError.invalidResponse("status_url")
        }
        guard let responseRaw = handle.responseURL, !responseRaw.isEmpty,
              let responseURL = resolveProviderURL(responseRaw) else {
            throw GenerationProviderError.invalidResponse("response_url")
        }

        let responseShape = parseResponseShape(from: handle.metadata)
        let timeoutSeconds = resolvedTimeoutSeconds()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastEmitted: GenerationProviderUpdate?

        while true {
            try Task.checkCancellation()
            if Date() >= deadline {
                throw GenerationProviderError.remoteFailure("timeout")
            }

            var request = URLRequest(url: statusURL)
            request.httpMethod = "GET"
            request.applyProviderHeaders(runtimeProfile)
            request.setValue("application/json", forHTTPHeaderField: "accept")

            let response = try await perform(request)
            let json = try decodeJSON(response.data)
            guard case .object(let object) = json else {
                throw GenerationProviderError.invalidResponse("status")
            }

            let status = (stringValue(object["status"]) ?? "").uppercased()
            switch status {
            case "IN_QUEUE":
                if lastEmitted != .queued {
                    continuation.yield(.queued)
                    lastEmitted = .queued
                }
            case "IN_PROGRESS":
                let progress = numberValue(object["progress"]).map { min(1, max(0, $0)) }
                let update = GenerationProviderUpdate.running(progress: progress)
                if lastEmitted != update {
                    continuation.yield(update)
                    lastEmitted = update
                }
            case "COMPLETED":
                let artifacts = try await fetchArtifacts(
                    responseURL: responseURL,
                    responseShape: responseShape
                )
                continuation.yield(.succeeded(artifacts))
                return
            case "FAILED", "CANCELLED", "ERROR":
                continuation.yield(.failed(code: status.lowercased()))
                return
            default:
                throw GenerationProviderError.invalidResponse("status")
            }

            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(2))
        }
    }

    private func fetchArtifacts(
        responseURL: URL,
        responseShape: CatalogEntry.ResponseShape
    ) async throws -> [GenerationArtifact] {
        var request = URLRequest(url: responseURL)
        request.httpMethod = "GET"
        request.applyProviderHeaders(runtimeProfile)
        request.setValue("application/json", forHTTPHeaderField: "accept")

        let response = try await perform(request)
        let json = try decodeJSON(response.data)
        guard case .object(let object) = json else {
            throw GenerationProviderError.invalidResponse("response")
        }
        let urls = try extractArtifactURLs(from: object, shape: responseShape)
        guard !urls.isEmpty else {
            throw GenerationProviderError.invalidResponse("artifacts")
        }
        return urls.map { GenerationArtifact.remoteURL($0) }
    }

    private func extractArtifactURLs(
        from object: [String: JSONValue],
        shape: CatalogEntry.ResponseShape
    ) throws -> [URL] {
        switch shape {
        case .video:
            guard case .object(let video)? = object["video"],
                  case .string(let raw) = video["url"],
                  let url = absoluteHTTPURL(raw) else {
                throw GenerationProviderError.invalidResponse("video.url")
            }
            return [url]
        case .images:
            guard case .array(let items) = object["images"] else {
                throw GenerationProviderError.invalidResponse("images")
            }
            let urls = items.compactMap { item -> URL? in
                guard case .object(let image) = item,
                      case .string(let raw) = image["url"] else { return nil }
                return absoluteHTTPURL(raw)
            }
            if urls.isEmpty {
                throw GenerationProviderError.invalidResponse("images")
            }
            return urls
        case .audio:
            guard case .object(let audio)? = object["audio"],
                  case .string(let raw) = audio["url"],
                  let url = absoluteHTTPURL(raw) else {
                throw GenerationProviderError.invalidResponse("audio.url")
            }
            return [url]
        case .upscaledImage:
            guard case .object(let image)? = object["image"],
                  case .string(let raw) = image["url"],
                  let url = absoluteHTTPURL(raw) else {
                throw GenerationProviderError.invalidResponse("image.url")
            }
            return [url]
        }
    }

    // MARK: - Start response

    private func parseStartResponse(
        _ json: JSONValue,
        modelID: String,
        responseShape: CatalogEntry.ResponseShape
    ) throws -> GenerationProviderStart {
        guard case .object(let object) = json else {
            throw GenerationProviderError.invalidResponse("start")
        }

        guard case .string(let requestID) = object["request_id"], !requestID.isEmpty else {
            throw GenerationProviderError.invalidResponse("request_id")
        }

        let statusURL = try optionalResolvedURL(stringValue(object["status_url"]))
        let responseURL = try optionalResolvedURL(stringValue(object["response_url"]))
        let cancelURL = try optionalResolvedURL(stringValue(object["cancel_url"]))

        let handle = GenerationJobHandle(
            providerProfileID: runtimeProfile.profile.id,
            providerKind: .falQueue,
            remoteID: requestID,
            statusURL: statusURL?.absoluteString,
            responseURL: responseURL?.absoluteString,
            cancelURL: cancelURL?.absoluteString,
            metadata: [
                "responseShape": .string(responseShape.rawValue),
                "modelID": .string(modelID),
            ]
        )
        return .job(handle)
    }

    // MARK: - Helpers

    private func validateFalProfile() throws {
        guard runtimeProfile.profile.generation != nil else {
            throw GenerationProviderError.missingGenerationService
        }
        guard runtimeProfile.profile.generation?.providerKind == .falQueue else {
            throw GenerationProviderError.providerMismatch
        }
    }

    private func resolvedTimeoutSeconds() -> TimeInterval {
        let options = runtimeProfile.profile.generation?.options ?? [:]
        let raw: Double
        if case .number(let value) = options["timeoutSeconds"] {
            raw = value
        } else {
            raw = 1800
        }
        return min(7200, max(60, raw))
    }

    private func parseResponseShape(from metadata: [String: JSONValue]) -> CatalogEntry.ResponseShape {
        if case .string(let raw) = metadata["responseShape"],
           let shape = CatalogEntry.ResponseShape(rawValue: raw) {
            return shape
        }
        return .video
    }

    private func optionalResolvedURL(_ raw: String?) throws -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let url = resolveProviderURL(raw) else {
            throw GenerationProviderError.invalidResponse("url")
        }
        return url
    }

    private func resolveProviderURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let base = try? AIProviderEndpoint.normalizedBaseURL(
                  runtimeProfile.profile.baseURL,
                  allowInsecureHTTP: runtimeProfile.profile.allowInsecureHTTP
              ) else {
            return nil
        }

        let candidate: URL?
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            candidate = absolute
        } else {
            candidate = URL(string: trimmed, relativeTo: base)?.absoluteURL
        }
        guard let candidate,
              let scheme = candidate.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = candidate.host else {
            return nil
        }
        if scheme == "http",
           !AIProviderEndpoint.isLoopbackHost(host),
           !runtimeProfile.profile.allowInsecureHTTP {
            return nil
        }
        if !AIProviderEndpoint.sameOrigin(candidate, base),
           !runtimeProfile.profile.allowCredentialRedirects {
            return nil
        }
        return candidate
    }

    private func absoluteHTTPURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
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

    private func perform(_ request: URLRequest) async throws -> AIHTTPDataResponse {
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
        return response
    }

    private func decodeJSON(_ data: Data) throws -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw GenerationProviderError.invalidResponse("json")
        }
    }

    private func stringValue(_ value: JSONValue?) -> String? {
        if case .string(let string) = value { return string }
        return nil
    }

    private func numberValue(_ value: JSONValue?) -> Double? {
        if case .number(let number) = value { return number }
        return nil
    }
}

// MARK: - FileType mapping

private extension FileType {
    static func inferred(from url: URL) -> FileType {
        switch url.pathExtension.lowercased() {
        case "png": .imagePng
        case "webp": .imageWebp
        case "gif": .imageGif
        case "jpg", "jpeg": .imageJpeg
        case "mp4", "m4v", "mov": .videoMp4
        case "mp3": .audioMp3
        case "wav": .audioWav
        default: .applicationStream
        }
    }
}
