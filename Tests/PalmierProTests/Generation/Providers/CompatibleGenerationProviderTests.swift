import Foundation
import Testing
@testable import PalmierPro

@Suite("Compatible Generation v1 catalog")
struct CompatibleGenerationCatalogTests {
    @Test func localModelsCoverFourKindsFilterAndQualifiedIDs() async throws {
        let profileID = UUID()
        let runtime = makeRuntimeProfile(
            id: profileID,
            modelIDs: ["vid-1", "img-1"],
            options: [
                "models": .array([
                    .object([
                        "id": .string("vid-1"),
                        "kind": .string("video"),
                        "display_name": .string("Video One"),
                        "capabilities": .object([
                            "durations": .array([.number(5), .number(10)]),
                            "aspect_ratios": .array([.string("16:9")]),
                            "supports_first_frame": .bool(true),
                            "max_reference_images": .number(2),
                        ]),
                    ]),
                    .object([
                        "id": .string("img-1"),
                        "kind": .string("image"),
                        "capabilities": .object([
                            "aspect_ratios": .array([.string("1:1")]),
                            "max_images": .number(8),
                            "supports_image_reference": .bool(true),
                        ]),
                    ]),
                    .object([
                        "id": .string("aud-1"),
                        "kind": .string("audio"),
                        "display_name": .string("Audio One"),
                        "capabilities": .object([
                            "category": .string("music"),
                            "supports_lyrics": .bool(true),
                        ]),
                    ]),
                    .object([
                        "id": .string("up-1"),
                        "kind": .string("upscale"),
                        "capabilities": .object([
                            "speed": .string("Fast"),
                            "p75_duration_seconds": .number(12),
                            "supported_types": .array([.string("video")]),
                        ]),
                    ]),
                ]),
            ]
        )

        let transport = FakeGenerationTransport()
        let entries = try await CompatibleGenerationCatalog.entries(
            runtimeProfile: runtime,
            transport: transport
        )

        #expect(transport.recorded.isEmpty)
        #expect(entries.count == 2)

        let video = try #require(entries.first { $0.kind == .video })
        #expect(video.id == GenerationModelIdentifier.qualify(profileID: profileID, modelID: "vid-1"))
        #expect(video.providerProfileID == profileID)
        #expect(video.providerKind == .compatibleV1)
        #expect(video.providerModelID == "vid-1")
        #expect(video.displayName == "Video One")
        #expect(video.paidOnly == false)
        #expect(video.creditsPerSecond == nil)
        #expect(video.audioPricing == nil)
        if case .video(let caps) = video.uiCapabilities {
            #expect(caps.durations == [5, 10])
            #expect(caps.aspectRatios == ["16:9"])
            #expect(caps.supportsFirstFrame)
            #expect(caps.maxReferenceImages == 2)
            #expect(caps.maxReferenceVideos == 0)
            #expect(caps.referenceTagNoun == "Image")
            #expect(!caps.supportsLastFrame)
        } else {
            Issue.record("expected video caps")
        }

        let image = try #require(entries.first { $0.kind == .image })
        #expect(image.id == GenerationModelIdentifier.qualify(profileID: profileID, modelID: "img-1"))
        #expect(image.displayName == "img-1")
        if case .image(let caps) = image.uiCapabilities {
            #expect(caps.maxImages == 4)
            #expect(caps.supportsImageReference)
            #expect(caps.aspectRatios == ["1:1"])
        } else {
            Issue.record("expected image caps")
        }
    }

    @Test func localModelsParseAudioAndUpscaleDefaultsWhenUnfiltered() async throws {
        let runtime = makeRuntimeProfile(
            options: [
                "models": .array([
                    .object([
                        "id": .string("aud-1"),
                        "kind": .string("audio"),
                    ]),
                    .object([
                        "id": .string("up-1"),
                        "kind": .string("upscale"),
                    ]),
                ]),
            ]
        )

        let entries = try await CompatibleGenerationCatalog.entries(
            runtimeProfile: runtime,
            transport: FakeGenerationTransport()
        )
        #expect(entries.count == 2)

        let audio = try #require(entries.first { $0.kind == .audio })
        if case .audio(let caps) = audio.uiCapabilities {
            #expect(caps.category == "tts")
            #expect(!caps.supportsLyrics)
            #expect(caps.minPromptLength == 1)
        } else {
            Issue.record("expected audio caps")
        }

        let upscale = try #require(entries.first { $0.kind == .upscale })
        if case .upscale(let caps) = upscale.uiCapabilities {
            #expect(caps.speed == "Unknown")
            #expect(caps.p75DurationSeconds == 0)
            #expect(caps.supportedTypes.isEmpty)
        } else {
            Issue.record("expected upscale caps")
        }
    }

    @Test func remoteCatalogAcceptsDataAndTopLevelArrayEnvelopes() async throws {
        let dataEnvelope = Data(#"{"data":[{"id":"m-data","kind":"video","display_name":"From Data"}]}"#.utf8)
        let topLevel = Data(#"[{"id":"m-top","kind":"image"}]"#.utf8)

        for (payload, expectedID) in [(dataEnvelope, "m-data"), (topLevel, "m-top")] {
            let transport = FakeGenerationTransport { request in
                #expect(request.url?.absoluteString == "http://127.0.0.1:8787/v1/models")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")
                return try FakeGenerationTransport.http(status: 200, data: payload)
            }
            let runtime = makeRuntimeProfile(credential: "secret-key")
            let entries = try await CompatibleGenerationCatalog.entries(
                runtimeProfile: runtime,
                transport: transport
            )
            #expect(entries.count == 1)
            #expect(entries[0].providerModelID == expectedID)
        }
    }

    @Test func remoteCatalogAcceptsModelsEnvelope() async throws {
        let payload = Data(#"{"models":[{"id":"m-models","kind":"audio","display_name":"From Models"}]}"#.utf8)
        let transport = FakeGenerationTransport { _ in
            try FakeGenerationTransport.http(status: 200, data: payload)
        }
        let entries = try await CompatibleGenerationCatalog.entries(
            runtimeProfile: makeRuntimeProfile(),
            transport: transport
        )
        #expect(entries.count == 1)
        #expect(entries[0].providerModelID == "m-models")
        #expect(entries[0].displayName == "From Models")
    }

    @Test func remoteCatalogHTTPErrorDoesNotLeakBody() async throws {
        let transport = FakeGenerationTransport { _ in
            try FakeGenerationTransport.http(
                status: 502,
                data: Data(#"{"error":"super-secret-upstream-body"}"#.utf8)
            )
        }
        do {
            _ = try await CompatibleGenerationCatalog.entries(
                runtimeProfile: makeRuntimeProfile(),
                transport: transport
            )
            Issue.record("expected httpStatus error")
        } catch let error as GenerationProviderError {
            #expect(error == .httpStatus(502))
            #expect(!String(describing: error).contains("super-secret-upstream-body"))
            #expect(error.localizedDescription.contains("502"))
            #expect(!error.localizedDescription.contains("super-secret"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}

@Suite("Compatible Generation v1 provider")
@MainActor
struct CompatibleGenerationProviderTests {
    @Test func uploadPostsJSONFieldsAndReturnsURL() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("compat-upload-\(UUID().uuidString).txt")
        try Data("hello-ref".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let transport = FakeGenerationTransport { request in
            #expect(request.url?.absoluteString == "http://127.0.0.1:8787/v1/uploads")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")
            let body = try #require(request.httpBody)
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(object["filename"] as? String == fileURL.lastPathComponent)
            #expect(object["content_type"] as? String == "text/plain")
            let encoded = try #require(object["data_base64"] as? String)
            #expect(Data(base64Encoded: encoded) == Data("hello-ref".utf8))
            #expect(object["prompt"] == nil)
            return try FakeGenerationTransport.http(
                status: 200,
                data: Data(#"{"url":"https://cdn.example/ref.bin"}"#.utf8)
            )
        }

        let provider = CompatibleGenerationProvider(
            runtimeProfile: makeRuntimeProfile(credential: "secret-key"),
            transport: transport
        )
        let url = try await provider.uploadReference(fileURL: fileURL, contentType: "text/plain")
        #expect(url == "https://cdn.example/ref.bin")
    }

    @Test func startEncodesParamsBodyAndRelativeURLHandle() async throws {
        let transport = FakeGenerationTransport { request in
            #expect(request.url?.absoluteString == "http://127.0.0.1:8787/v1/jobs")
            #expect(request.httpMethod == "POST")
            let body = try #require(request.httpBody)
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(object["model"] as? String == "vid-1")
            #expect(object["project_id"] as? String == "proj-9")
            let input = try #require(object["input"] as? [String: Any])
            #expect(input["kind"] as? String == "video")
            #expect(input["prompt"] as? String == "a cat")
            #expect(input["duration"] as? Int == 5 || input["duration"] as? Double == 5)
            #expect(input["aspectRatio"] as? String == "16:9")
            return try FakeGenerationTransport.http(
                status: 200,
                data: Data(#"""
                {
                  "job_id":"job-42",
                  "status":"queued",
                  "status_url":"jobs/job-42",
                  "result_url":"jobs/job-42/result",
                  "cancel_url":"jobs/job-42/cancel"
                }
                """#.utf8)
            )
        }

        let profileID = UUID()
        let provider = CompatibleGenerationProvider(
            runtimeProfile: makeRuntimeProfile(id: profileID, credential: "secret-key"),
            transport: transport
        )
        let start = try await provider.start(
            request: GenerationProviderRequest(
                modelID: "vid-1",
                params: .video(VideoGenerationParams(
                    prompt: "a cat",
                    duration: 5,
                    aspectRatio: "16:9",
                    resolution: nil
                )),
                projectID: "proj-9"
            )
        )

        guard case .job(let handle) = start else {
            Issue.record("expected job handle")
            return
        }
        #expect(handle.remoteID == "job-42")
        #expect(handle.providerProfileID == profileID)
        #expect(handle.providerKind == .compatibleV1)
        #expect(handle.statusURL == "http://127.0.0.1:8787/v1/jobs/job-42")
        #expect(handle.responseURL == "http://127.0.0.1:8787/v1/jobs/job-42/result")
        #expect(handle.cancelURL == "http://127.0.0.1:8787/v1/jobs/job-42/cancel")
        #expect(handle.metadata == ["modelID": .string("vid-1")])
        #expect(handle.metadata["prompt"] == nil)
    }

    @Test func startOmitsProjectIDWhenNilAndSupportsImmediateCompleted() async throws {
        let transport = FakeGenerationTransport { request in
            let body = try #require(request.httpBody)
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(object["project_id"] == nil)
            return try FakeGenerationTransport.http(
                status: 200,
                data: Data(#"""
                {
                  "status":"completed",
                  "outputs":["https://cdn.example/out.mp4"]
                }
                """#.utf8)
            )
        }

        let provider = CompatibleGenerationProvider(
            runtimeProfile: makeRuntimeProfile(),
            transport: transport
        )
        let start = try await provider.start(
            request: GenerationProviderRequest(
                modelID: "vid-1",
                params: .video(VideoGenerationParams(
                    prompt: "done now",
                    duration: 4,
                    aspectRatio: "1:1",
                    resolution: nil
                )),
                projectID: nil
            )
        )

        guard case .completed(let artifacts) = start else {
            Issue.record("expected immediate completed")
            return
        }
        let expectedURL = try #require(URL(string: "https://cdn.example/out.mp4"))
        #expect(artifacts == [.remoteURL(expectedURL)])
    }

    @Test func startCompletedWithoutJobIDWhenOutputsPresent() async throws {
        let transport = FakeGenerationTransport { _ in
            try FakeGenerationTransport.http(
                status: 200,
                data: Data(#"""
                {"outputs":[{"url":"https://cdn.example/still.png"}]}
                """#.utf8)
            )
        }
        let provider = CompatibleGenerationProvider(
            runtimeProfile: makeRuntimeProfile(),
            transport: transport
        )
        let start = try await provider.start(
            request: GenerationProviderRequest(
                modelID: "img-1",
                params: .image(ImageGenerationParams(
                    prompt: "still",
                    aspectRatio: "1:1",
                    resolution: nil,
                    quality: nil,
                    imageURLs: [],
                    numImages: 1
                )),
                projectID: nil
            )
        )
        guard case .completed(let artifacts) = start else {
            Issue.record("expected completed")
            return
        }
        #expect(artifacts.count == 1)
    }

    @Test func updatesPollQueuedRunningCompletedViaResultPath() async throws {
        let counter = StatusCallCounter()
        let transport = FakeGenerationTransport { request in
            let url = try #require(request.url?.absoluteString)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")

            if url.hasSuffix("/jobs/job-7") {
                let call = await counter.next()
                switch call {
                case 1:
                    return try FakeGenerationTransport.http(
                        status: 200,
                        data: Data(#"{"status":"queued"}"#.utf8)
                    )
                case 2:
                    return try FakeGenerationTransport.http(
                        status: 200,
                        data: Data(#"{"status":"running","progress":0.4}"#.utf8)
                    )
                default:
                    return try FakeGenerationTransport.http(
                        status: 200,
                        data: Data(#"{"status":"succeeded"}"#.utf8)
                    )
                }
            }

            if url.hasSuffix("/jobs/job-7/result") {
                return try FakeGenerationTransport.http(
                    status: 200,
                    data: Data(#"{"result_urls":["https://cdn.example/final.mp4"]}"#.utf8)
                )
            }

            Issue.record("unexpected url \(url)")
            return try FakeGenerationTransport.http(status: 404, data: Data())
        }

        let profileID = UUID()
        let provider = CompatibleGenerationProvider(
            runtimeProfile: makeRuntimeProfile(
                id: profileID,
                credential: "secret-key",
                options: ["pollIntervalSeconds": .number(0.25)]
            ),
            transport: transport
        )
        let handle = GenerationJobHandle(
            providerProfileID: profileID,
            providerKind: .compatibleV1,
            remoteID: "job-7"
        )

        var updates: [GenerationProviderUpdate] = []
        for try await update in provider.updates(for: handle) {
            updates.append(update)
            if case .succeeded = update { break }
        }

        let finalURL = try #require(URL(string: "https://cdn.example/final.mp4"))
        #expect(updates == [
            .queued,
            .running(progress: 0.4),
            .succeeded([.remoteURL(finalURL)]),
        ])
    }

    @Test func updatesHTTPErrorDoesNotLeakBody() async throws {
        let transport = FakeGenerationTransport { _ in
            try FakeGenerationTransport.http(
                status: 500,
                data: Data(#"{"message":"internal-secret"}"#.utf8)
            )
        }
        let profileID = UUID()
        let provider = CompatibleGenerationProvider(
            runtimeProfile: makeRuntimeProfile(id: profileID),
            transport: transport
        )
        let handle = GenerationJobHandle(
            providerProfileID: profileID,
            providerKind: .compatibleV1,
            remoteID: "job-x"
        )

        do {
            for try await _ in provider.updates(for: handle) {}
            Issue.record("expected failure")
        } catch let error as GenerationProviderError {
            #expect(error == .httpStatus(500))
            #expect(!error.localizedDescription.contains("internal-secret"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func rejectsWrongProviderKind() async throws {
        let profile = AIProviderProfile(
            name: "Wrong",
            baseURL: "http://127.0.0.1:8787",
            allowInsecureHTTP: true,
            auth: ProviderAuthConfiguration(kind: .bearer),
            generation: GenerationEndpointConfiguration(
                providerKind: .openAIMedia,
                endpointPath: "v1"
            )
        )
        let runtime = AIProviderRuntimeProfile(
            profile: profile,
            primaryCredential: "x",
            headers: ["Authorization": "Bearer x"]
        )
        let provider = CompatibleGenerationProvider(
            runtimeProfile: runtime,
            transport: FakeGenerationTransport()
        )
        do {
            _ = try await provider.start(
                request: GenerationProviderRequest(
                    modelID: "m",
                    params: .image(ImageGenerationParams(
                        prompt: "x",
                        aspectRatio: "1:1",
                        resolution: nil,
                        quality: nil,
                        imageURLs: [],
                        numImages: 1
                    )),
                    projectID: nil
                )
            )
            Issue.record("expected mismatch")
        } catch let error as GenerationProviderError {
            #expect(error == .providerMismatch)
        }
    }

    @Test func startRejectsModelOutsideConfiguredAllowlist() async {
        let transport = FakeGenerationTransport { _ in
            Issue.record("must not network for allowlist rejection")
            return try FakeGenerationTransport.http(status: 500, data: Data())
        }
        let provider = CompatibleGenerationProvider(
            runtimeProfile: makeRuntimeProfile(modelIDs: ["img-1"]),
            transport: transport
        )
        do {
            _ = try await provider.start(
                request: GenerationProviderRequest(
                    modelID: "vid-1",
                    params: .video(VideoGenerationParams(
                        prompt: "x",
                        duration: 4,
                        aspectRatio: "16:9",
                        resolution: nil
                    )),
                    projectID: nil
                )
            )
            Issue.record("expected unsupported model")
        } catch let error as GenerationProviderError {
            #expect(error == .unsupported("vid-1"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func pollRejectsDifferentPortWhenCredentialRedirectsDisabled() async {
        let transport = FakeGenerationTransport { _ in
            Issue.record("must not poll cross-origin credential URL")
            return try FakeGenerationTransport.http(status: 500, data: Data())
        }
        let profileID = UUID()
        let provider = CompatibleGenerationProvider(
            runtimeProfile: makeRuntimeProfile(
                id: profileID,
                allowCredentialRedirects: false
            ),
            transport: transport
        )
        let handle = GenerationJobHandle(
            providerProfileID: profileID,
            providerKind: .compatibleV1,
            remoteID: "job-port",
            statusURL: "http://127.0.0.1:9999/v1/jobs/job-port",
            responseURL: "http://127.0.0.1:9999/v1/jobs/job-port/result"
        )
        do {
            for try await _ in provider.updates(for: handle) {}
            Issue.record("expected invalid url")
        } catch let error as GenerationProviderError {
            #expect(error == .invalidResponse("url"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func pollAllowsDifferentPortWhenCredentialRedirectsEnabled() async throws {
        let counter = StatusCallCounter()
        let transport = FakeGenerationTransport { request in
            let url = try #require(request.url?.absoluteString)
            #expect(url.hasPrefix("http://127.0.0.1:9999/"))
            if url.hasSuffix("/jobs/job-redirect") {
                let call = await counter.next()
                if call == 1 {
                    return try FakeGenerationTransport.http(
                        status: 200,
                        data: Data(#"{"status":"succeeded","outputs":["https://cdn.example/ok.mp4"]}"#.utf8)
                    )
                }
            }
            Issue.record("unexpected url \(url)")
            return try FakeGenerationTransport.http(status: 404, data: Data())
        }
        let profileID = UUID()
        let provider = CompatibleGenerationProvider(
            runtimeProfile: makeRuntimeProfile(
                id: profileID,
                allowCredentialRedirects: true,
                options: ["pollIntervalSeconds": .number(0.25)]
            ),
            transport: transport
        )
        let handle = GenerationJobHandle(
            providerProfileID: profileID,
            providerKind: .compatibleV1,
            remoteID: "job-redirect",
            statusURL: "http://127.0.0.1:9999/v1/jobs/job-redirect",
            responseURL: "http://127.0.0.1:9999/v1/jobs/job-redirect/result"
        )

        var updates: [GenerationProviderUpdate] = []
        for try await update in provider.updates(for: handle) {
            updates.append(update)
            if case .succeeded = update { break }
        }
        let finalURL = try #require(URL(string: "https://cdn.example/ok.mp4"))
        #expect(updates == [.succeeded([.remoteURL(finalURL)])])
    }
}

// MARK: - Helpers

private func makeRuntimeProfile(
    id: UUID = UUID(),
    credential: String = "secret-key",
    modelIDs: [String] = [],
    allowCredentialRedirects: Bool = false,
    options: [String: JSONValue] = [:]
) -> AIProviderRuntimeProfile {
    let profile = AIProviderProfile(
        id: id,
        name: "Compatible",
        baseURL: "http://127.0.0.1:8787",
        allowInsecureHTTP: true,
        allowCredentialRedirects: allowCredentialRedirects,
        auth: ProviderAuthConfiguration(kind: .bearer),
        generation: GenerationEndpointConfiguration(
            providerKind: .compatibleV1,
            endpointPath: "v1",
            modelIDs: modelIDs,
            options: options
        )
    )
    return AIProviderRuntimeProfile(
        profile: profile,
        primaryCredential: credential,
        headers: ["Authorization": "Bearer \(credential)"]
    )
}

private actor StatusCallCounter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}

private final class FakeGenerationTransport: AIHTTPTransporting, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> AIHTTPDataResponse

    private let handler: Handler
    private let lock = NSLock()
    private(set) var recorded: [URLRequest] = []

    init(handler: @escaping Handler = { _ in
        try FakeGenerationTransport.http(status: 500, data: Data())
    }) {
        self.handler = handler
    }

    func data(for request: URLRequest, maxResponseBytes: Int) async throws -> AIHTTPDataResponse {
        lock.withLock {
            recorded.append(request)
        }
        return try await handler(request)
    }

    func lines(for request: URLRequest) async throws -> AIHTTPLineResponse {
        throw AIHTTPTransportError.nonHTTPResponse
    }

    static func http(status: Int, data: Data) throws -> AIHTTPDataResponse {
        guard let url = URL(string: "http://127.0.0.1:8787/v1") else {
            throw GenerationProviderError.invalidResponse("test-url")
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            throw GenerationProviderError.invalidResponse("test-response")
        }
        return AIHTTPDataResponse(data: data, response: response)
    }
}
