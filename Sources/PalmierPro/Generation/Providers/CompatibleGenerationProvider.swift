import Foundation

struct CompatibleGenerationProvider: GenerationProvider {
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
        try validateCompatibleProfile()
        let options = CompatibleGenerationOptions(runtimeProfile.profile.generation?.options ?? [:])
        let root = try CompatibleGenerationEndpoint.root(for: runtimeProfile.profile)
        let url = try CompatibleGenerationEndpoint.resolvePath(
            options.uploadsPath,
            root: root,
            allowInsecureHTTP: runtimeProfile.profile.allowInsecureHTTP
        )

        let fileData: Data
        do {
            fileData = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: fileURL)
            }.value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GenerationProviderError.transport(error.localizedDescription)
        }

        let body: [String: Any] = [
            "filename": fileURL.lastPathComponent,
            "content_type": contentType,
            "data_base64": fileData.base64EncodedString(),
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.applyProviderHeaders(runtimeProfile)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let response = try await perform(request)
        let json = try decodeJSON(response.data)
        guard case .object(let object) = json,
              case .string(let uploaded) = object["url"],
              !uploaded.isEmpty else {
            throw GenerationProviderError.invalidResponse("upload.url")
        }
        return try CompatibleGenerationEndpoint.resolveProviderURL(
            uploaded,
            root: root,
            allowInsecureHTTP: runtimeProfile.profile.allowInsecureHTTP,
            allowCrossHost: true
        ).absoluteString
    }

    func start(request: GenerationProviderRequest) async throws -> GenerationProviderStart {
        try validateCompatibleProfile()
        if let generation = runtimeProfile.profile.generation {
            try GenerationProviderModelAllowlist.validate(
                modelID: request.modelID,
                generation: generation
            )
        }
        let options = CompatibleGenerationOptions(runtimeProfile.profile.generation?.options ?? [:])
        let root = try CompatibleGenerationEndpoint.root(for: runtimeProfile.profile)
        let url = try CompatibleGenerationEndpoint.resolvePath(
            options.jobsPath,
            root: root,
            allowInsecureHTTP: runtimeProfile.profile.allowInsecureHTTP
        )

        let inputObject = try encodeInputObject(request.params)
        var body: [String: Any] = [
            "model": request.modelID,
            "input": inputObject,
        ]
        if let projectID = request.projectID {
            body["project_id"] = projectID
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.applyProviderHeaders(runtimeProfile)
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "accept")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let response = try await perform(urlRequest)
        let json = try decodeJSON(response.data)
        return try parseStartResponse(json, root: root, modelID: request.modelID)
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
        try validateCompatibleProfile()
        guard handle.providerProfileID == runtimeProfile.profile.id,
              handle.providerKind == .compatibleV1 else {
            throw GenerationProviderError.providerMismatch
        }

        let options = CompatibleGenerationOptions(runtimeProfile.profile.generation?.options ?? [:])
        let root = try CompatibleGenerationEndpoint.root(for: runtimeProfile.profile)
        let allowInsecure = runtimeProfile.profile.allowInsecureHTTP
        let statusURL = try resolveStatusURL(handle: handle, root: root, options: options, allowInsecure: allowInsecure)
        let resultURL = try resolveResultURL(handle: handle, root: root, options: options, allowInsecure: allowInsecure)

        let deadline = Date().addingTimeInterval(options.timeoutSeconds)
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

            let status = (CompatibleJSON.string(object["status"]) ?? "").lowercased()
            switch status {
            case "queued", "pending":
                if lastEmitted != .queued {
                    continuation.yield(.queued)
                    lastEmitted = .queued
                }
            case "running", "in_progress", "processing":
                let progress = CompatibleJSON.double(object["progress"]).map { min(1, max(0, $0)) }
                let update = GenerationProviderUpdate.running(progress: progress)
                if lastEmitted != update {
                    continuation.yield(update)
                    lastEmitted = update
                }
            case "succeeded", "completed":
                let artifacts = try await resolveSucceededArtifacts(
                    object: object,
                    resultURL: resultURL
                )
                continuation.yield(.succeeded(artifacts))
                return
            case "failed", "error", "cancelled":
                continuation.yield(.failed(code: status))
                return
            default:
                throw GenerationProviderError.invalidResponse("status")
            }

            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(options.pollIntervalSeconds))
        }
    }

    private func resolveSucceededArtifacts(
        object: [String: JSONValue],
        resultURL: URL
    ) async throws -> [GenerationArtifact] {
        if let artifacts = try? parseArtifacts(from: object), !artifacts.isEmpty {
            return artifacts
        }

        var request = URLRequest(url: resultURL)
        request.httpMethod = "GET"
        request.applyProviderHeaders(runtimeProfile)
        request.setValue("application/json", forHTTPHeaderField: "accept")

        let response = try await perform(request)
        let json = try decodeJSON(response.data)
        guard case .object(let resultObject) = json else {
            throw GenerationProviderError.invalidResponse("result")
        }
        return try parseArtifacts(from: resultObject)
    }

    // MARK: - Start response

    private func parseStartResponse(
        _ json: JSONValue,
        root: URL,
        modelID: String
    ) throws -> GenerationProviderStart {
        guard case .object(let object) = json else {
            throw GenerationProviderError.invalidResponse("start")
        }

        let allowInsecure = runtimeProfile.profile.allowInsecureHTTP
        let status = (CompatibleJSON.string(object["status"]) ?? "").lowercased()
        let jobID = firstString(object, keys: ["job_id", "id"])
        let outputs = try? parseArtifacts(from: object)

        if let outputs, !outputs.isEmpty {
            if status == "succeeded" || status == "completed" || jobID == nil {
                return .completed(outputs)
            }
        }

        guard let remoteID = jobID, !remoteID.isEmpty else {
            throw GenerationProviderError.invalidResponse("job_id")
        }

        let statusURL = try optionalProviderURL(
            firstString(object, keys: ["status_url"]),
            root: root,
            allowInsecure: allowInsecure
        )
        let responseURL = try optionalProviderURL(
            firstString(object, keys: ["result_url", "response_url"]),
            root: root,
            allowInsecure: allowInsecure
        )
        let cancelURL = try optionalProviderURL(
            firstString(object, keys: ["cancel_url"]),
            root: root,
            allowInsecure: allowInsecure
        )

        let handle = GenerationJobHandle(
            providerProfileID: runtimeProfile.profile.id,
            providerKind: .compatibleV1,
            remoteID: remoteID,
            statusURL: statusURL?.absoluteString,
            responseURL: responseURL?.absoluteString,
            cancelURL: cancelURL?.absoluteString,
            metadata: ["modelID": .string(modelID)]
        )
        return .job(handle)
    }

    // MARK: - Artifacts

    private func parseArtifacts(from object: [String: JSONValue]) throws -> [GenerationArtifact] {
        var urls: [URL] = []

        if let list = object["outputs"] ?? object["result_urls"] {
            switch list {
            case .array(let items):
                for item in items {
                    if let url = absoluteURL(from: item) {
                        urls.append(url)
                    }
                }
            case .string:
                if let url = absoluteURL(from: list) {
                    urls.append(url)
                }
            default:
                break
            }
        }

        for key in ["result_url", "output_url", "url"] {
            if let url = absoluteURL(from: object[key]) {
                urls.append(url)
            }
        }

        // Deduplicate while preserving order.
        var seen = Set<String>()
        var unique: [URL] = []
        unique.reserveCapacity(urls.count)
        for url in urls {
            let key = url.absoluteString
            if seen.insert(key).inserted {
                unique.append(url)
            }
        }

        guard !unique.isEmpty else {
            throw GenerationProviderError.invalidResponse("outputs")
        }
        return unique.map { GenerationArtifact.remoteURL($0) }
    }

    private func absoluteURL(from value: JSONValue?) -> URL? {
        switch value {
        case .string(let raw)?:
            return absoluteHTTPURL(raw)
        case .object(let object)?:
            if case .string(let raw) = object["url"] {
                return absoluteHTTPURL(raw)
            }
            return nil
        default:
            return nil
        }
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

    // MARK: - URL helpers

    private func resolveStatusURL(
        handle: GenerationJobHandle,
        root: URL,
        options: CompatibleGenerationOptions,
        allowInsecure: Bool
    ) throws -> URL {
        if let raw = handle.statusURL, !raw.isEmpty {
            let url = try CompatibleGenerationEndpoint.resolveProviderURL(
                raw,
                root: root,
                allowInsecureHTTP: allowInsecure,
                allowCrossHost: runtimeProfile.profile.allowCredentialRedirects
            )
            try ensureCredentialURLOrigin(url, relativeTo: root)
            return url
        }
        return try CompatibleGenerationEndpoint.resolvePath(
            "\(options.jobsPath)/\(handle.remoteID)",
            root: root,
            allowInsecureHTTP: allowInsecure
        )
    }

    private func resolveResultURL(
        handle: GenerationJobHandle,
        root: URL,
        options: CompatibleGenerationOptions,
        allowInsecure: Bool
    ) throws -> URL {
        if let raw = handle.responseURL, !raw.isEmpty {
            let url = try CompatibleGenerationEndpoint.resolveProviderURL(
                raw,
                root: root,
                allowInsecureHTTP: allowInsecure,
                allowCrossHost: runtimeProfile.profile.allowCredentialRedirects
            )
            try ensureCredentialURLOrigin(url, relativeTo: root)
            return url
        }
        return try CompatibleGenerationEndpoint.resolvePath(
            "\(options.jobsPath)/\(handle.remoteID)/result",
            root: root,
            allowInsecureHTTP: allowInsecure
        )
    }

    private func optionalProviderURL(
        _ raw: String?,
        root: URL,
        allowInsecure: Bool
    ) throws -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        let url = try CompatibleGenerationEndpoint.resolveProviderURL(
            raw,
            root: root,
            allowInsecureHTTP: allowInsecure,
            allowCrossHost: runtimeProfile.profile.allowCredentialRedirects
        )
        try ensureCredentialURLOrigin(url, relativeTo: root)
        return url
    }

    /// Credential-bearing status/result URLs must match base origin unless redirects are allowed.
    private func ensureCredentialURLOrigin(_ url: URL, relativeTo root: URL) throws {
        if AIProviderEndpoint.sameOrigin(url, root) { return }
        if runtimeProfile.profile.allowCredentialRedirects { return }
        throw GenerationProviderError.invalidResponse("url")
    }

    // MARK: - Transport

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

    private func encodeInputObject(_ params: BackendGenerationParams) throws -> [String: Any] {
        let data: Data
        do {
            data = try JSONEncoder().encode(params)
        } catch {
            throw GenerationProviderError.invalidResponse("input")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GenerationProviderError.invalidResponse("input")
        }
        return object
    }

    private func validateCompatibleProfile() throws {
        guard runtimeProfile.profile.generation != nil else {
            throw GenerationProviderError.missingGenerationService
        }
        guard runtimeProfile.profile.generation?.providerKind == .compatibleV1 else {
            throw GenerationProviderError.providerMismatch
        }
    }

    private func firstString(_ object: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if case .string(let value) = object[key], !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
