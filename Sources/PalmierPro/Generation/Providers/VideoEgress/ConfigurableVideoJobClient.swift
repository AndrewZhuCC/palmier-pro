import Foundation

struct ConfigurableVideoJobClient: Sendable {
    private static let jsonMaxBytes = 8 * 1_024 * 1_024
    private static let mediaMaxBytes = 256 * 1_024 * 1_024
    private static let pollIntervalSeconds: Double = 2
    private static let defaultTimeoutSeconds: Double = 1_800
    private static let timeoutRange: ClosedRange<Double> = 60...7_200
    private static let unknownStatusGracePolls = 5

    let runtimeProfile: AIProviderRuntimeProfile
    let profile: VideoEgressProfile
    private let transport: any AIHTTPTransporting

    init(
        runtimeProfile: AIProviderRuntimeProfile,
        profile: VideoEgressProfile,
        transport: any AIHTTPTransporting
    ) {
        self.runtimeProfile = runtimeProfile
        self.profile = profile
        self.transport = transport
    }

    func start(
        modelID: String,
        params: VideoGenerationParams
    ) async throws -> GenerationProviderStart {
        try profile.validate()
        if params.sourceVideoURL != nil
            || params.endFrameURL != nil
            || !params.referenceVideoURLs.isEmpty
            || !params.referenceAudioURLs.isEmpty {
            throw GenerationProviderError.unsupported("video references")
        }
        let caps = profile.capabilities
        let maxImages = caps?.maxReferenceImages ?? 0
        let supportsFirst = caps?.supportsFirstFrame ?? false
        if (params.startFrameURL != nil || !params.referenceImageURLs.isEmpty),
           !supportsFirst, maxImages == 0 {
            throw GenerationProviderError.unsupported("video references")
        }

        let context = VideoEgressRenderContext(model: modelID, params: params)
        let createPath = try VideoEgressRenderer.renderPath(profile.create.path, context: context)
        let url = try resolveEndpoint(createPath)

        var request = URLRequest(url: url)
        request.httpMethod = profile.create.method.uppercased()
        request.applyProviderHeaders(runtimeProfile)
        request.setValue("application/json", forHTTPHeaderField: "accept")

        let contentType = profile.create.contentType.lowercased()
        if contentType == "application/json" {
            let body = try VideoEgressRenderer.renderCreateBody(
                required: profile.create.body,
                optional: profile.create.optional,
                context: context
            )
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            // Match other providers: encode via Foundation JSON, not JSONEncoder(JSONValue).
            do {
                request.httpBody = try JSONSerialization.data(
                    withJSONObject: body.foundationValue,
                    options: [.sortedKeys]
                )
            } catch {
                throw GenerationProviderError.invalidResponse("videoProfile body encode")
            }
            if case .object(let object) = body {
                let promptLen: Int
                if case .string(let prompt) = object["prompt"] {
                    promptLen = prompt.count
                } else {
                    promptLen = 0
                }
                Log.generation.notice(
                    "video egress create profile=\(profile.id) model=\(modelID) promptChars=\(promptLen) keys=\(object.keys.sorted().joined(separator: ","))"
                )
            }
        } else {
            let fields = try VideoEgressRenderer.renderMultipartFields(
                fields: profile.create.fields ?? [:],
                optional: profile.create.optional,
                context: context
            )
            let boundary = UUID().uuidString
            request.setValue(
                "multipart/form-data; boundary=\(boundary)",
                forHTTPHeaderField: "content-type"
            )
            request.httpBody = Self.multipartBody(boundary: boundary, fields: fields)
        }

        let response = try await perform(request, maxResponseBytes: Self.jsonMaxBytes)
        let json = try decodeJSON(response.data)
        guard let remoteID = VideoEgressRenderer.string(atDotPath: profile.job.idPath, in: json),
              !remoteID.isEmpty else {
            throw GenerationProviderError.invalidResponse("video id")
        }

        var jobContext = context
        jobContext.jobId = remoteID
        let statusPath = try VideoEgressRenderer.renderPath(profile.job.status.path, context: jobContext)
        let statusURL = try resolveEndpoint(statusPath)

        var contentURLString: String?
        if let contentTemplate = profile.job.result.fallbackContentPath {
            let contentPath = try VideoEgressRenderer.renderPath(contentTemplate, context: jobContext)
            contentURLString = try resolveEndpoint(contentPath).absoluteString
        }

        let handle = GenerationJobHandle(
            providerProfileID: runtimeProfile.profile.id,
            providerKind: .openAIMedia,
            remoteID: remoteID,
            statusURL: statusURL.absoluteString,
            responseURL: contentURLString,
            metadata: [
                "modelID": .string(modelID),
                "videoProfileID": .string(profile.id),
            ]
        )
        return .job(handle)
    }

    func pollUpdates(
        for handle: GenerationJobHandle,
        continuation: AsyncThrowingStream<GenerationProviderUpdate, Error>.Continuation
    ) async throws {
        guard handle.providerProfileID == runtimeProfile.profile.id,
              handle.providerKind == .openAIMedia else {
            throw GenerationProviderError.providerMismatch
        }
        guard let statusRaw = handle.statusURL else {
            throw GenerationProviderError.invalidResponse("handle urls")
        }
        let statusURL = try validatedCredentialURL(statusRaw)
        let contentURL = try handle.responseURL.map(validatedCredentialURL)

        let timeout = timeoutSeconds()
        let deadline = Date().addingTimeInterval(timeout)
        var unknownCount = 0

        while true {
            try Task.checkCancellation()
            if Date() >= deadline {
                throw GenerationProviderError.remoteFailure("timeout")
            }

            var request = URLRequest(url: statusURL)
            request.httpMethod = profile.job.status.method.uppercased()
            request.applyProviderHeaders(runtimeProfile)
            request.setValue("application/json", forHTTPHeaderField: "accept")

            let response = try await perform(request, maxResponseBytes: Self.jsonMaxBytes)
            let json = try decodeJSON(response.data)
            let rawStatus = (
                VideoEgressRenderer.string(atDotPath: profile.job.status.statusPath, in: json) ?? ""
            ).lowercased()
            let normalized = profile.job.status.map[rawStatus].flatMap(VideoEgressNormalizedStatus.init(rawValue:))

            switch normalized {
            case .queued:
                unknownCount = 0
                continuation.yield(.queued)
            case .running:
                unknownCount = 0
                let progress = progressValue(in: json)
                continuation.yield(.running(progress: progress))
            case .succeeded:
                let artifacts = try await resolveArtifacts(statusJSON: json, contentURL: contentURL)
                continuation.yield(.succeeded(artifacts))
                return
            case .failed:
                continuation.yield(.failed(code: rawStatus.isEmpty ? "failed" : rawStatus))
                return
            case .none:
                if rawStatus.isEmpty {
                    unknownCount += 1
                } else {
                    unknownCount += 1
                }
                if unknownCount > Self.unknownStatusGracePolls {
                    throw GenerationProviderError.invalidResponse("status")
                }
            }

            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(Self.pollIntervalSeconds))
        }
    }

    // MARK: - Result

    private func resolveArtifacts(
        statusJSON: JSONValue,
        contentURL: URL?
    ) async throws -> [GenerationArtifact] {
        for path in profile.job.result.prefer {
            if let raw = VideoEgressRenderer.string(atDotPath: path, in: statusJSON),
               let url = safeArtifactURL(raw) {
                return [.remoteURL(url)]
            }
        }
        if let contentURL {
            let data = try await fetchBinary(from: contentURL)
            return [.data(data, fileExtension: "mp4")]
        }
        throw GenerationProviderError.invalidResponse("video result")
    }

    private func fetchBinary(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.applyProviderHeaders(runtimeProfile)
        let response = try await perform(request, maxResponseBytes: Self.mediaMaxBytes)
        guard !response.data.isEmpty else {
            throw GenerationProviderError.invalidResponse("video content")
        }
        return response.data
    }

    private func progressValue(in json: JSONValue) -> Double? {
        guard let path = profile.job.status.progressPath,
              let value = VideoEgressRenderer.value(atDotPath: path, in: json) else {
            return nil
        }
        let number: Double?
        switch value {
        case .number(let n): number = n
        case .string(let s): number = Double(s)
        default: number = nil
        }
        guard let number, number.isFinite else { return nil }
        if number >= 0, number <= 1 { return number }
        if number > 1, number <= 100 { return number / 100 }
        return nil
    }

    // MARK: - Transport / URL

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

    private static func multipartBody(boundary: String, fields: [(String, String)]) -> Data {
        var body = Data()
        let crlf = "\r\n"
        for (name, value) in fields {
            body.append(Data("--\(boundary)\(crlf)".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\(crlf)".utf8))
            body.append(Data(crlf.utf8))
            body.append(Data("\(value)\(crlf)".utf8))
        }
        body.append(Data("--\(boundary)--\(crlf)".utf8))
        return body
    }
}
