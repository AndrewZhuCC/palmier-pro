import Foundation
import Testing
@testable import PalmierPro

@Suite("Fal generation catalog")
struct FalGenerationCatalogTests {
    private let profileID = UUID(uuidString: "11111111-1111-4111-8111-111111111111") ?? UUID()

    private func falProfile(modelIDs: [String] = []) -> AIProviderProfile {
        AIProviderProfile(
            id: profileID,
            name: "fal.ai",
            baseURL: "https://queue.fal.run",
            auth: ProviderAuthConfiguration(
                kind: .customHeader,
                headerName: "Authorization",
                valuePrefix: "Key "
            ),
            generation: GenerationEndpointConfiguration(
                providerKind: .falQueue,
                modelIDs: modelIDs
            )
        )
    }

    @Test func qualifiesCatalogIDs() {
        let entries = FalGenerationCatalog.entries(profile: falProfile())
        #expect(!entries.isEmpty)
        let seedance = entries.first { $0.providerModelID == "seedance-2" }
        #expect(seedance != nil)
        #expect(
            seedance?.id == GenerationModelIdentifier.qualify(
                profileID: profileID,
                modelID: "seedance-2"
            )
        )
        #expect(seedance?.providerProfileID == profileID)
        #expect(seedance?.providerKind == .falQueue)
        #expect(seedance?.paidOnly == false)
        #expect(seedance?.creditsPerSecond == nil)
        #expect(seedance?.creditsPerImage == nil)
        #expect(seedance?.audioPricing == nil)
        #expect(seedance?.creditsPerSecondUpscale == nil)
    }

    @Test func filtersByConfiguredModelIDs() {
        let entries = FalGenerationCatalog.entries(
            profile: falProfile(modelIDs: ["kling-v3", "nano-banana-pro"])
        )
        let rawIDs = Set(entries.compactMap(\.providerModelID))
        #expect(rawIDs == Set(["kling-v3", "nano-banana-pro"]))
    }

    @Test func encodesSeedanceReferenceCapabilities() throws {
        let entries = FalGenerationCatalog.entries(profile: falProfile())
        let entry = try #require(entries.first { $0.providerModelID == "seedance-2" })
        guard case .video(let caps) = entry.uiCapabilities else {
            Issue.record("expected video caps")
            return
        }
        #expect(caps.durations == Array(4...15))
        #expect(caps.resolutions == ["480p", "720p", "1080p"])
        #expect(caps.aspectRatios == ["auto", "21:9", "16:9", "4:3", "1:1", "3:4", "9:16"])
        #expect(caps.maxReferenceImages == 9)
        #expect(caps.maxReferenceVideos == 3)
        #expect(caps.maxReferenceAudios == 3)
        #expect(caps.maxTotalReferences == 12)
        #expect(caps.maxCombinedVideoRefSeconds == 15)
        #expect(caps.maxCombinedAudioRefSeconds == 15)
        #expect(caps.framesAndReferencesExclusive)
        #expect(caps.referenceTagNoun == "Image")
        #expect(!caps.requiresSourceVideo)
    }

    @Test func seedanceRefsEndpointAndBody() throws {
        let definition = try FalGenerationCatalog.request(
            modelID: "seedance-2",
            params: .video(VideoGenerationParams(
                prompt: "dance",
                duration: 8,
                aspectRatio: "16:9",
                resolution: "720p",
                referenceImageURLs: ["https://cdn.example/a.png"],
                referenceVideoURLs: ["https://cdn.example/b.mp4"],
                referenceAudioURLs: ["https://cdn.example/c.mp3"],
                generateAudio: true
            ))
        )
        #expect(definition.endpoint == "bytedance/seedance-2.0/reference-to-video")
        #expect(definition.body["prompt"] == .string("dance"))
        #expect(definition.body["image_urls"] == .array([.string("https://cdn.example/a.png")]))
        #expect(definition.body["video_urls"] == .array([.string("https://cdn.example/b.mp4")]))
        #expect(definition.body["audio_urls"] == .array([.string("https://cdn.example/c.mp3")]))
        #expect(definition.body["duration"] == .string("8"))
        #expect(definition.body["generate_audio"] == .bool(true))
        #expect(definition.body["image_url"] == nil)
        #expect(definition.responseShape == .video)
    }

    @Test func kling4kUsesStartImageKeyAndFrameOnlyEndpoint() throws {
        let definition = try FalGenerationCatalog.request(
            modelID: "kling-v3",
            params: .video(VideoGenerationParams(
                prompt: "walk",
                duration: 5,
                aspectRatio: "16:9",
                resolution: "4k",
                startFrameURL: "https://cdn.example/start.png",
                referenceImageURLs: ["https://cdn.example/elem.png"],
                generateAudio: false
            ))
        )
        #expect(definition.endpoint == "fal-ai/kling-video/v3/4k/image-to-video")
        // With elements, Kling V3 4k uses start_image_url (not image_url).
        #expect(definition.body["start_image_url"] == .string("https://cdn.example/start.png"))
        #expect(definition.body["image_url"] == nil)
        #expect(definition.body["generate_audio"] == .bool(false))
        #expect(definition.body["duration"] == .string("5"))
        #expect(definition.body["aspect_ratio"] == nil)
        #expect(definition.body["elements"] != nil)
    }

    @Test func veoFirstLastFrameEndpointAndBody() throws {
        let definition = try FalGenerationCatalog.request(
            modelID: "veo3.1",
            params: .video(VideoGenerationParams(
                prompt: "pan",
                duration: 6,
                aspectRatio: "16:9",
                resolution: "1080p",
                startFrameURL: "https://cdn.example/first.png",
                endFrameURL: "https://cdn.example/last.png",
                generateAudio: true
            ))
        )
        #expect(definition.endpoint == "fal-ai/veo3.1/first-last-frame-to-video")
        #expect(definition.body["first_frame_url"] == .string("https://cdn.example/first.png"))
        #expect(definition.body["last_frame_url"] == .string("https://cdn.example/last.png"))
        #expect(definition.body["duration"] == .string("6s"))
        #expect(definition.body["generate_audio"] == .bool(true))
        #expect(definition.body["image_url"] == nil)
    }

    @Test func nanoEditEndpointAndBody() throws {
        let definition = try FalGenerationCatalog.request(
            modelID: "nano-banana-pro",
            params: .image(ImageGenerationParams(
                prompt: "restyle",
                aspectRatio: "16:9",
                resolution: "2K",
                quality: nil,
                imageURLs: ["https://cdn.example/ref.png"],
                numImages: 2
            ))
        )
        #expect(definition.endpoint == "fal-ai/nano-banana-pro/edit")
        #expect(definition.body["prompt"] == .string("restyle"))
        #expect(definition.body["output_format"] == .string("jpeg"))
        #expect(definition.body["aspect_ratio"] == .string("16:9"))
        #expect(definition.body["resolution"] == .string("2K"))
        #expect(definition.body["image_urls"] == .array([.string("https://cdn.example/ref.png")]))
        #expect(definition.body["num_images"] == .number(2))
        #expect(definition.responseShape == .images)
    }

    @Test func grokImageBodyAndEndpoint() throws {
        let definition = try FalGenerationCatalog.request(
            modelID: "grok-imagine",
            params: .image(ImageGenerationParams(
                prompt: "sky",
                aspectRatio: "16:9",
                resolution: nil,
                quality: nil,
                imageURLs: [],
                numImages: 1
            ))
        )
        #expect(definition.endpoint == "xai/grok-imagine-image")
        #expect(definition.body["prompt"] == .string("sky"))
        #expect(definition.body["aspect_ratio"] == .string("16:9"))
        #expect(definition.body["image_urls"] == nil)
        #expect(definition.body["num_images"] == nil)
    }

    @Test func ttsBodyAndEndpoint() throws {
        let definition = try FalGenerationCatalog.request(
            modelID: "elevenlabs-tts-v3",
            params: .audio(AudioGenerationParams(
                prompt: "Hello world",
                voice: "Rachel",
                lyrics: nil,
                styleInstructions: nil,
                instrumental: false,
                durationSeconds: nil
            ))
        )
        #expect(definition.endpoint == "fal-ai/elevenlabs/tts/eleven-v3")
        #expect(definition.body["text"] == .string("Hello world"))
        #expect(definition.body["voice"] == .string("Rachel"))
        #expect(definition.responseShape == .audio)
    }

    @Test func upscaleBodyAndEndpoint() throws {
        let definition = try FalGenerationCatalog.request(
            modelID: "bytedance-upscaler",
            params: .upscale(UpscaleGenerationParams(
                sourceURL: "https://cdn.example/clip.mp4",
                durationSeconds: 12
            ))
        )
        #expect(definition.endpoint == "fal-ai/bytedance-upscaler/upscale/video")
        #expect(definition.body["video_url"] == .string("https://cdn.example/clip.mp4"))
        #expect(definition.body["target_resolution"] == .string("4k"))
        #expect(definition.responseShape == .video)
    }

    @Test func rejectsUnknownModel() {
        #expect(throws: GenerationProviderError.unsupported("not-a-model")) {
            _ = try FalGenerationCatalog.request(
                modelID: "not-a-model",
                params: .video(VideoGenerationParams(
                    prompt: "x",
                    duration: 4,
                    aspectRatio: "16:9",
                    resolution: "720p"
                ))
            )
        }
    }

    @Test func rejectsParamKindMismatchAsUnsupported() {
        #expect(throws: GenerationProviderError.unsupported("seedance-2")) {
            _ = try FalGenerationCatalog.request(
                modelID: "seedance-2",
                params: .image(ImageGenerationParams(
                    prompt: "x",
                    aspectRatio: "16:9",
                    resolution: "2K",
                    quality: nil,
                    imageURLs: [],
                    numImages: 1
                ))
            )
        }
    }
}

@Suite("Fal generation provider")
@MainActor
struct FalGenerationProviderTests {
    private let profileID = UUID(uuidString: "22222222-2222-4222-8222-222222222222") ?? UUID()

    private func runtimeProfile(
        baseURL: String = "https://queue.fal.run",
        modelIDs: [String] = [],
        allowCredentialRedirects: Bool = false
    ) -> AIProviderRuntimeProfile {
        let profile = AIProviderProfile(
            id: profileID,
            name: "fal.ai",
            baseURL: baseURL,
            allowCredentialRedirects: allowCredentialRedirects,
            auth: ProviderAuthConfiguration(
                kind: .customHeader,
                headerName: "Authorization",
                valuePrefix: "Key "
            ),
            generation: GenerationEndpointConfiguration(
                providerKind: .falQueue,
                modelIDs: modelIDs
            )
        )
        return AIProviderRuntimeProfile(
            profile: profile,
            primaryCredential: "test-key",
            headers: ["Authorization": "Key test-key"]
        )
    }

    @Test func startParsesWhitelistAndRelativeURLs() async throws {
        let transport = FalFakeTransport { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString == "https://queue.fal.run/bytedance/seedance-2.0/text-to-video")
            #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
            let body = try #require(request.httpBody)
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            #expect(object?["prompt"] as? String == "hello")
            #expect(object?["duration"] as? String == "4")
            #expect(object?["generate_audio"] as? Bool == true)
            return try FalFakeTransport.json(
                [
                    "request_id": "req-1",
                    "status_url": "/requests/req-1/status",
                    "response_url": "/requests/req-1",
                    "cancel_url": "https://queue.fal.run/requests/req-1/cancel",
                    "detail": "should-not-be-stored",
                    "secret": "nope",
                ]
            )
        }

        let provider = FalGenerationProvider(
            runtimeProfile: runtimeProfile(),
            transport: transport
        )
        let start = try await provider.start(request: GenerationProviderRequest(
            modelID: "seedance-2",
            params: .video(VideoGenerationParams(
                prompt: "hello",
                duration: 4,
                aspectRatio: "16:9",
                resolution: "720p"
            )),
            projectID: nil
        ))

        guard case .job(let handle) = start else {
            Issue.record("expected job handle")
            return
        }
        #expect(handle.remoteID == "req-1")
        #expect(handle.providerProfileID == profileID)
        #expect(handle.providerKind == .falQueue)
        #expect(handle.statusURL == "https://queue.fal.run/requests/req-1/status")
        #expect(handle.responseURL == "https://queue.fal.run/requests/req-1")
        #expect(handle.cancelURL == "https://queue.fal.run/requests/req-1/cancel")
        #expect(handle.metadata["responseShape"] == .string("video"))
        #expect(handle.metadata["modelID"] == .string("seedance-2"))
        #expect(handle.metadata["detail"] == nil)
        #expect(handle.metadata["secret"] == nil)
        #expect(handle.metadata["body"] == nil)
    }

    @Test func httpErrorDoesNotExposeBody() async {
        let transport = FalFakeTransport { _ in
            try FalFakeTransport.http(
                status: 422,
                data: Data(#"{"detail":"invalid prompt","message":"secret"}"#.utf8)
            )
        }
        let provider = FalGenerationProvider(
            runtimeProfile: runtimeProfile(),
            transport: transport
        )

        do {
            _ = try await provider.start(request: GenerationProviderRequest(
                modelID: "seedance-2",
                params: .video(VideoGenerationParams(
                    prompt: "hello",
                    duration: 4,
                    aspectRatio: "16:9",
                    resolution: "720p"
                )),
                projectID: nil
            ))
            Issue.record("expected httpStatus error")
        } catch let error as GenerationProviderError {
            #expect(error == .httpStatus(422))
            let description = error.localizedDescription
            #expect(!description.contains("invalid prompt"))
            #expect(!description.contains("secret"))
        } catch {
            Issue.record("unexpected error type")
        }
    }

    @Test func updatesProgressThenCompletedArtifacts() async throws {
        actor CallCounter {
            private var count = 0
            func next() -> Int {
                count += 1
                return count
            }
        }
        let counter = CallCounter()

        let transport = FalFakeTransport { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/status") {
                let n = await counter.next()
                if n == 1 {
                    return try FalFakeTransport.json([
                        "status": "IN_PROGRESS",
                        "progress": 0.4,
                    ])
                }
                return try FalFakeTransport.json([
                    "status": "COMPLETED",
                ])
            }
            if path.hasSuffix("/response") {
                return try FalFakeTransport.json([
                    "video": ["url": "https://cdn.example/out.mp4"],
                    "detail": "ignore",
                ])
            }
            Issue.record("unexpected request \(path)")
            return try FalFakeTransport.http(status: 404, data: Data())
        }

        let provider = FalGenerationProvider(
            runtimeProfile: runtimeProfile(),
            transport: transport
        )
        let handle = GenerationJobHandle(
            providerProfileID: profileID,
            providerKind: .falQueue,
            remoteID: "req-2",
            statusURL: "https://queue.fal.run/requests/req-2/status",
            responseURL: "https://queue.fal.run/requests/req-2/response",
            metadata: [
                "responseShape": .string("video"),
                "modelID": .string("seedance-2"),
            ]
        )

        var updates: [GenerationProviderUpdate] = []
        for try await update in provider.updates(for: handle) {
            updates.append(update)
        }

        #expect(updates.count == 2)
        #expect(updates[0] == .running(progress: 0.4))
        guard case .succeeded(let artifacts) = updates[1] else {
            Issue.record("expected succeeded")
            return
        }
        let artifactURL = try #require(URL(string: "https://cdn.example/out.mp4"))
        #expect(artifacts == [.remoteURL(artifactURL)])
    }

    @Test func statusFailureYieldsFailedWithoutProviderMessage() async throws {
        let transport = FalFakeTransport { _ in
            try FalFakeTransport.json([
                "status": "FAILED",
                "error": "internal explosion",
                "detail": "secret",
            ])
        }
        let provider = FalGenerationProvider(
            runtimeProfile: runtimeProfile(),
            transport: transport
        )
        let handle = GenerationJobHandle(
            providerProfileID: profileID,
            providerKind: .falQueue,
            remoteID: "req-3",
            statusURL: "https://queue.fal.run/requests/req-3/status",
            responseURL: "https://queue.fal.run/requests/req-3/response",
            metadata: ["responseShape": .string("video"), "modelID": .string("seedance-2")]
        )

        var updates: [GenerationProviderUpdate] = []
        for try await update in provider.updates(for: handle) {
            updates.append(update)
        }
        #expect(updates == [.failed(code: "failed")])
    }

    @Test func startRejectsModelOutsideConfiguredAllowlist() async {
        let transport = FalFakeTransport { _ in
            Issue.record("must not network for allowlist rejection")
            return try FalFakeTransport.http(status: 500, data: Data())
        }
        let provider = FalGenerationProvider(
            runtimeProfile: runtimeProfile(modelIDs: ["kling-v3"]),
            transport: transport
        )
        do {
            _ = try await provider.start(request: GenerationProviderRequest(
                modelID: "seedance-2",
                params: .video(VideoGenerationParams(
                    prompt: "hello",
                    duration: 4,
                    aspectRatio: "16:9",
                    resolution: "720p"
                )),
                projectID: nil
            ))
            Issue.record("expected unsupported model")
        } catch let error as GenerationProviderError {
            #expect(error == .unsupported("seedance-2"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func uploadRejectsCustomBaseBeforeUsingFalSDK() async {
        let transport = FalFakeTransport { _ in
            Issue.record("must not use HTTP transport")
            return try FalFakeTransport.http(status: 500, data: Data())
        }
        let provider = FalGenerationProvider(
            runtimeProfile: runtimeProfile(baseURL: "https://fal-gateway.example"),
            transport: transport
        )
        do {
            _ = try await provider.uploadReference(
                fileURL: URL(fileURLWithPath: "/tmp/does-not-exist.png"),
                contentType: "image/png"
            )
            Issue.record("expected custom base upload rejection")
        } catch let error as GenerationProviderError {
            #expect(error == .unsupported(
                "fal.ai SDK uploads require the official queue.fal.run base URL"
            ))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}

// MARK: - Fake transport

private final class FalFakeTransport: AIHTTPTransporting, @unchecked Sendable {
    private let handler: @Sendable (URLRequest) async throws -> AIHTTPDataResponse

    init(handler: @escaping @Sendable (URLRequest) async throws -> AIHTTPDataResponse) {
        self.handler = handler
    }

    func data(for request: URLRequest, maxResponseBytes: Int) async throws -> AIHTTPDataResponse {
        _ = maxResponseBytes
        return try await handler(request)
    }

    func lines(for request: URLRequest) async throws -> AIHTTPLineResponse {
        throw GenerationProviderError.unsupported("lines")
    }

    static func json(_ object: [String: Any], status: Int = 200) throws -> AIHTTPDataResponse {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try http(status: status, data: data)
    }

    static func http(status: Int, data: Data) throws -> AIHTTPDataResponse {
        guard let url = URL(string: "https://queue.fal.run/fake"),
              let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            throw GenerationProviderError.invalidResponse("fake transport")
        }
        return AIHTTPDataResponse(data: data, response: response)
    }
}
