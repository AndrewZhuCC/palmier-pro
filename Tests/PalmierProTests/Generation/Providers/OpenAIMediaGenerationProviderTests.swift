import Foundation
import Testing
@testable import PalmierPro

@Suite("OpenAI Media catalog")
struct OpenAIMediaGenerationCatalogTests {
    @Test func defaultsThreeModelsWithoutSora() {
        let profile = openAIMediaProfile(modelIDs: [])
        let entries = OpenAIMediaGenerationCatalog.entries(profile: profile)
        let rawIDs = entries.compactMap(\.providerModelID)
        #expect(rawIDs == ["gpt-image-2", "tts-1", "tts-1-hd"])
        #expect(entries.allSatisfy { $0.providerKind == .openAIMedia })
        #expect(entries.allSatisfy { $0.paidOnly == false })
        #expect(entries.allSatisfy { $0.creditsPerImage == nil })
        #expect(entries.allSatisfy { $0.creditsPerSecond == nil })
        #expect(entries.allSatisfy { $0.audioPricing == nil })
    }

    @Test func qualifiesEntryIDsWithProfile() throws {
        let profile = openAIMediaProfile(modelIDs: [])
        let entries = OpenAIMediaGenerationCatalog.entries(profile: profile)
        for entry in entries {
            let raw = try #require(entry.providerModelID)
            #expect(entry.id == GenerationModelIdentifier.qualify(profileID: profile.id, modelID: raw))
            #expect(entry.providerProfileID == profile.id)
        }
    }

    @Test func includesExplicitSoraModels() throws {
        let profile = openAIMediaProfile(modelIDs: ["sora-2", "sora-2-pro", "gpt-image-2"])
        let entries = OpenAIMediaGenerationCatalog.entries(profile: profile)
        let rawIDs = Set(entries.compactMap(\.providerModelID))
        #expect(rawIDs == ["gpt-image-2", "sora-2", "sora-2-pro"])

        let sora = try #require(entries.first(where: { $0.providerModelID == "sora-2" }))
        #expect(sora.displayName == "Sora 2")
        if case .video(let caps) = sora.uiCapabilities {
            #expect(caps.durations == [4, 8, 12])
            #expect(caps.resolutions == ["720p", "1080p"])
            #expect(caps.aspectRatios == ["16:9", "9:16"])
            #expect(caps.supportsFirstFrame == false)
            #expect(caps.supportsLastFrame == false)
            #expect(caps.maxReferenceImages == 0)
        } else {
            Issue.record("Expected video capabilities for sora-2")
        }
    }

    @Test func filtersByModelIDs() {
        let profile = openAIMediaProfile(modelIDs: ["tts-1-hd"])
        let entries = OpenAIMediaGenerationCatalog.entries(profile: profile)
        #expect(entries.map(\.providerModelID) == ["tts-1-hd"])
    }

    @Test func includesExplicitCustomVideoModelWithFifteenSecondDuration() throws {
        let profile = openAIMediaProfile(
            modelIDs: ["grok-imagine-video"],
            options: ["videoProfile": .string("json-seconds-aspect")]
        )
        let entries = OpenAIMediaGenerationCatalog.entries(profile: profile)
        let entry = try #require(entries.first(where: { $0.providerModelID == "grok-imagine-video" }))

        #expect(entry.kind == .video)
        if case .video(let caps) = entry.uiCapabilities {
            #expect(caps.durations == [4, 8, 12, 15])
            #expect(caps.resolutions == ["720p"])
            #expect(caps.aspectRatios == ["16:9", "9:16"])
            #expect(caps.supportsFirstFrame == true)
        } else {
            Issue.record("Expected custom video capabilities")
        }
    }

    @Test func imageAndTTSCapabilities() throws {
        let profile = openAIMediaProfile(modelIDs: [])
        let entries = OpenAIMediaGenerationCatalog.entries(profile: profile)

        let image = try #require(entries.first(where: { $0.providerModelID == "gpt-image-2" }))
        #expect(image.displayName == "GPT Image 2")
        if case .image(let caps) = image.uiCapabilities {
            #expect(caps.resolutions == ["1024x1024", "1024x1536", "1536x1024"])
            #expect(caps.aspectRatios.isEmpty)
            #expect(caps.qualities == ["low", "medium", "high"])
            #expect(caps.supportsImageReference)
            #expect(caps.maxImages == 4)
        } else {
            Issue.record("Expected image capabilities")
        }

        let tts = try #require(entries.first(where: { $0.providerModelID == "tts-1" }))
        if case .audio(let caps) = tts.uiCapabilities {
            #expect(caps.category == "tts")
            #expect(caps.voices == ["alloy", "echo", "fable", "onyx", "nova", "shimmer"])
            #expect(caps.defaultVoice == "alloy")
            #expect(caps.inputs == ["text"])
            #expect(caps.minPromptLength == 1)
        } else {
            Issue.record("Expected audio capabilities")
        }
    }
}

@Suite("OpenAI Media provider")
@MainActor
struct OpenAIMediaGenerationProviderTests {
    @Test func imageJSONBodyAndMixedArtifacts() async throws {
        let transport = FakeOpenAIMediaTransport { request in
            #expect(request.url?.absoluteString == "https://api.openai.com/v1/images/generations")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")

            let body = try #require(request.httpBody)
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(object["model"] as? String == "gpt-image-2")
            #expect(object["prompt"] as? String == "a cat")
            #expect(object["n"] as? Int == 2 || object["n"] as? Double == 2)
            #expect(object["size"] as? String == "1024x1024")
            #expect(object["quality"] as? String == "high")

            let pngBytes = Data([0x89, 0x50, 0x4E, 0x47])
            let payload: [String: Any] = [
                "data": [
                    ["b64_json": pngBytes.base64EncodedString()],
                    ["url": "https://cdn.example/out.png"],
                ],
            ]
            return try FakeOpenAIMediaTransport.jsonResponse(payload)
        }

        let provider = OpenAIMediaGenerationProvider(
            runtimeProfile: openAIMediaRuntime(),
            transport: transport
        )
        let start = try await provider.start(request: GenerationProviderRequest(
            modelID: "gpt-image-2",
            params: .image(ImageGenerationParams(
                prompt: "a cat",
                aspectRatio: "1:1",
                resolution: "1024x1024",
                quality: "high",
                imageURLs: [],
                numImages: 2
            )),
            projectID: nil
        ))

        guard case .completed(let artifacts) = start else {
            Issue.record("Expected completed image artifacts")
            return
        }
        #expect(artifacts.count == 2)
        #expect(artifacts[0] == .data(Data([0x89, 0x50, 0x4E, 0x47]), fileExtension: "png"))
        #expect(artifacts[1] == .remoteURL(try #require(URL(string: "https://cdn.example/out.png"))))
    }

    @Test func imageEditMultipartContainsImagePartsAndOmitsBodyFromErrors() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openai-media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("a.png")
        let second = directory.appendingPathComponent("b.jpg")
        try Data([0x01, 0x02]).write(to: first)
        try Data([0x03, 0x04]).write(to: second)

        let secretPrompt = "do-not-leak-this-prompt"

        let transport = FakeOpenAIMediaTransport { request in
            #expect(request.url?.absoluteString == "https://api.openai.com/v1/images/edits")
            let contentType = try #require(request.value(forHTTPHeaderField: "content-type"))
            #expect(contentType.hasPrefix("multipart/form-data; boundary="))
            let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
            let body = try #require(request.httpBody)
            let text = String(decoding: body, as: UTF8.self)
            #expect(text.contains("name=\"model\""))
            #expect(text.contains("gpt-image-2"))
            #expect(text.contains("name=\"prompt\""))
            #expect(text.contains(secretPrompt))
            #expect(text.contains("name=\"image[]\"; filename=\"a.png\""))
            #expect(text.contains("name=\"image[]\"; filename=\"b.jpg\""))
            #expect(body.range(of: Data("--\(boundary)".utf8)) != nil)
            #expect(text.contains("\r\n"))
            #expect(!text.contains("\n\n--"))

            return try FakeOpenAIMediaTransport.http(
                status: 400,
                data: Data("{\"error\":\"\(secretPrompt)\"}".utf8)
            )
        }

        let provider = OpenAIMediaGenerationProvider(
            runtimeProfile: openAIMediaRuntime(),
            transport: transport
        )

        do {
            _ = try await provider.start(request: GenerationProviderRequest(
                modelID: "gpt-image-2",
                params: .image(ImageGenerationParams(
                    prompt: secretPrompt,
                    aspectRatio: "1:1",
                    resolution: nil,
                    quality: nil,
                    imageURLs: [first.absoluteString, second.absoluteString],
                    numImages: 1
                )),
                projectID: nil
            ))
            Issue.record("Expected HTTP error")
        } catch let error as GenerationProviderError {
            #expect(error == .httpStatus(400))
            #expect(error.localizedDescription.contains(secretPrompt) == false)
            #expect(String(describing: error).contains(secretPrompt) == false)
        }
    }

    @Test func ttsJSONBodyAndBinaryArtifact() async throws {
        let audioBytes = Data("ID3fake-mp3".utf8)
        let transport = FakeOpenAIMediaTransport { request in
            #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/speech")
            let body = try #require(request.httpBody)
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(object["model"] as? String == "tts-1")
            #expect(object["input"] as? String == "hello world")
            #expect(object["voice"] as? String == "nova")
            #expect(object["response_format"] as? String == "mp3")
            return try FakeOpenAIMediaTransport.http(status: 200, data: audioBytes)
        }

        let provider = OpenAIMediaGenerationProvider(
            runtimeProfile: openAIMediaRuntime(),
            transport: transport
        )
        let start = try await provider.start(request: GenerationProviderRequest(
            modelID: "tts-1",
            params: .audio(AudioGenerationParams(
                prompt: "hello world",
                voice: "nova",
                lyrics: nil,
                styleInstructions: nil,
                instrumental: false,
                durationSeconds: nil
            )),
            projectID: nil
        ))

        guard case .completed(let artifacts) = start,
              case .data(let data, let ext) = artifacts.first else {
            Issue.record("Expected mp3 data artifact")
            return
        }
        #expect(data == audioBytes)
        #expect(ext == "mp3")
    }

    @Test func rejectsSourceAudio() async throws {
        let transport = FakeOpenAIMediaTransport { _ in
            Issue.record("Should not network for unsupported audio source")
            return try FakeOpenAIMediaTransport.http(status: 500, data: Data())
        }
        let provider = OpenAIMediaGenerationProvider(
            runtimeProfile: openAIMediaRuntime(),
            transport: transport
        )

        do {
            _ = try await provider.start(request: GenerationProviderRequest(
                modelID: "tts-1",
                params: .audio(AudioGenerationParams(
                    prompt: "hi",
                    voice: nil,
                    lyrics: nil,
                    styleInstructions: nil,
                    instrumental: false,
                    durationSeconds: nil,
                    sourceURL: "file:///tmp/a.wav"
                )),
                projectID: nil
            ))
            Issue.record("Expected unsupported audio source")
        } catch let error as GenerationProviderError {
            #expect(error == .unsupported("audio source"))
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func videoSizeMappingAndHandlePaths() async throws {
        let transport = FakeOpenAIMediaTransport { request in
            #expect(request.url?.absoluteString == "https://api.openai.com/v1/videos")
            let contentType = try #require(request.value(forHTTPHeaderField: "content-type"))
            #expect(contentType.hasPrefix("multipart/form-data; boundary="))
            let bodyText = String(decoding: try #require(request.httpBody), as: UTF8.self)
            #expect(bodyText.contains("name=\"model\""))
            #expect(bodyText.contains("sora-2"))
            #expect(bodyText.contains("name=\"prompt\""))
            #expect(bodyText.contains("name=\"seconds\""))
            #expect(bodyText.contains("8"))
            #expect(bodyText.contains("name=\"size\""))
            #expect(bodyText.contains("1280x720"))

            return try FakeOpenAIMediaTransport.jsonResponse([
                "id": "video_123",
                "status": "queued",
                "progress": 0,
                "secret": "ignore-me",
            ])
        }

        let provider = OpenAIMediaGenerationProvider(
            runtimeProfile: openAIMediaRuntime(),
            transport: transport
        )
        let start = try await provider.start(request: GenerationProviderRequest(
            modelID: "sora-2",
            params: .video(VideoGenerationParams(
                prompt: "ocean waves",
                duration: 8,
                aspectRatio: "16:9",
                resolution: "720p"
            )),
            projectID: nil
        ))

        guard case .job(let handle) = start else {
            Issue.record("Expected video job handle")
            return
        }
        #expect(handle.providerKind == .openAIMedia)
        #expect(handle.remoteID == "video_123")
        #expect(handle.statusURL == "https://api.openai.com/v1/videos/video_123")
        #expect(handle.responseURL == "https://api.openai.com/v1/videos/video_123/content")
        #expect(handle.metadata["modelID"] == .string("sora-2"))
    }

    @Test func customVideoModelUsesJSONSecondsAspectProfile() async throws {
        let transport = FakeOpenAIMediaTransport { request in
            #expect(request.url?.absoluteString == "https://api.openai.com/v1/videos")
            #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
            let body = try #require(request.httpBody)
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(object["model"] as? String == "grok-imagine-video")
            #expect(object["prompt"] as? String == "a neon city at dusk")
            #expect(object["seconds"] as? String == "15")
            #expect(object["aspect_ratio"] as? String == "16:9")
            #expect(object["size"] as? String == "1280x720")
            return try FakeOpenAIMediaTransport.jsonResponse([
                "id": "grok_video_123",
                "status": "processing",
            ])
        }

        let runtime = openAIMediaRuntime(
            modelIDs: ["grok-imagine-video"],
            options: ["videoProfile": .string("json-seconds-aspect")]
        )
        let provider = OpenAIMediaGenerationProvider(runtimeProfile: runtime, transport: transport)
        let start = try await provider.start(request: GenerationProviderRequest(
            modelID: "grok-imagine-video",
            params: .video(VideoGenerationParams(
                prompt: "a neon city at dusk",
                duration: 15,
                aspectRatio: "16:9",
                resolution: "720p"
            )),
            projectID: nil
        ))

        guard case .job(let handle) = start else {
            Issue.record("Expected custom video job handle")
            return
        }
        #expect(handle.remoteID == "grok_video_123")
        #expect(handle.metadata["modelID"] == JSONValue.string("grok-imagine-video"))
        #expect(handle.metadata["videoProfileID"] == JSONValue.string("json-seconds-aspect"))
    }

    @Test func jsonDurationAspectUsesIntegerDurationAndDownloadURL() async throws {
        actor CallCounter {
            var count = 0
            func next() -> Int {
                count += 1
                return count
            }
        }
        let counter = CallCounter()
        let transport = FakeOpenAIMediaTransport { request in
            let path = try #require(request.url?.absoluteString)
            if path.hasSuffix("/videos"), request.httpMethod == "POST" {
                #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
                let body = try #require(request.httpBody)
                let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(object["duration"] as? Int == 15 || object["duration"] as? Double == 15)
                #expect(object["aspect_ratio"] as? String == "16:9")
                let params = try #require(object["params"] as? [String: Any])
                #expect(params["resolution"] as? String == "720p")
                return try FakeOpenAIMediaTransport.jsonResponse([
                    "id": "hub_1",
                    "status": "processing",
                ])
            }
            if path.hasSuffix("/videos/hub_1") {
                let n = await counter.next()
                if n == 1 {
                    return try FakeOpenAIMediaTransport.jsonResponse([
                        "id": "hub_1",
                        "status": "processing",
                        "progress": 40,
                    ])
                }
                return try FakeOpenAIMediaTransport.jsonResponse([
                    "id": "hub_1",
                    "status": "completed",
                    "progress": 100,
                    "download_url": "https://cdn.example/out.mp4",
                ])
            }
            Issue.record("Unexpected URL \(path)")
            return try FakeOpenAIMediaTransport.http(status: 404, data: Data())
        }

        let runtime = openAIMediaRuntime(
            modelIDs: ["grok-imagine-video"],
            options: [
                "videoProfile": .string("json-duration-aspect"),
                "timeoutSeconds": .number(60),
            ]
        )
        let provider = OpenAIMediaGenerationProvider(runtimeProfile: runtime, transport: transport)
        let start = try await provider.start(request: GenerationProviderRequest(
            modelID: "grok-imagine-video",
            params: .video(VideoGenerationParams(
                prompt: "harbor sunset",
                duration: 15,
                aspectRatio: "16:9",
                resolution: "720p"
            )),
            projectID: nil
        ))
        guard case .job(let handle) = start else {
            Issue.record("Expected job handle")
            return
        }

        var updates: [GenerationProviderUpdate] = []
        for try await update in provider.updates(for: handle) {
            updates.append(update)
            if case .succeeded = update { break }
        }
        #expect(updates.contains(.running(progress: 0.4)))
        guard case .succeeded(let artifacts) = updates.last,
              case .remoteURL(let url) = artifacts.first else {
            Issue.record("Expected remote URL artifact")
            return
        }
        #expect(url.absoluteString == "https://cdn.example/out.mp4")
    }

    @Test func videoPollProgressThenContent() async throws {
        let mp4 = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70])
        actor CallCounter {
            var count = 0
            func next() -> Int {
                count += 1
                return count
            }
        }
        let counter = CallCounter()

        let transport = FakeOpenAIMediaTransport { request in
            let path = try #require(request.url?.absoluteString)
            if path.hasSuffix("/videos/video_abc") {
                let n = await counter.next()
                if n == 1 {
                    return try FakeOpenAIMediaTransport.jsonResponse([
                        "id": "video_abc",
                        "status": "queued",
                    ])
                }
                if n == 2 {
                    return try FakeOpenAIMediaTransport.jsonResponse([
                        "id": "video_abc",
                        "status": "in_progress",
                        "progress": 40,
                    ])
                }
                return try FakeOpenAIMediaTransport.jsonResponse([
                    "id": "video_abc",
                    "status": "completed",
                    "progress": 100,
                ])
            }
            if path.hasSuffix("/videos/video_abc/content") {
                return try FakeOpenAIMediaTransport.http(status: 200, data: mp4)
            }
            Issue.record("Unexpected URL \(path)")
            return try FakeOpenAIMediaTransport.http(status: 404, data: Data())
        }

        let runtime = openAIMediaRuntime(options: ["timeoutSeconds": .number(60)])
        let provider = OpenAIMediaGenerationProvider(runtimeProfile: runtime, transport: transport)
        let handle = GenerationJobHandle(
            providerProfileID: runtime.profile.id,
            providerKind: .openAIMedia,
            remoteID: "video_abc",
            statusURL: "https://api.openai.com/v1/videos/video_abc",
            responseURL: "https://api.openai.com/v1/videos/video_abc/content",
            metadata: ["modelID": .string("sora-2")]
        )

        var updates: [GenerationProviderUpdate] = []
        for try await update in provider.updates(for: handle) {
            updates.append(update)
            if case .succeeded = update { break }
        }

        #expect(updates.contains(.queued))
        #expect(updates.contains(.running(progress: 0.4)))
        guard case .succeeded(let artifacts) = updates.last,
              case .data(let data, let ext) = artifacts.first else {
            Issue.record("Expected succeeded mp4 artifact")
            return
        }
        #expect(data == mp4)
        #expect(ext == "mp4")
    }

    @Test func httpErrorDoesNotIncludeResponseBody() async throws {
        let secret = "super-secret-error-body"
        let transport = FakeOpenAIMediaTransport { _ in
            try FakeOpenAIMediaTransport.http(status: 429, data: Data(secret.utf8))
        }
        let provider = OpenAIMediaGenerationProvider(
            runtimeProfile: openAIMediaRuntime(),
            transport: transport
        )

        do {
            _ = try await provider.start(request: GenerationProviderRequest(
                modelID: "gpt-image-2",
                params: .image(ImageGenerationParams(
                    prompt: "x",
                    aspectRatio: "1:1",
                    resolution: nil,
                    quality: nil,
                    imageURLs: [],
                    numImages: 1
                )),
                projectID: nil
            ))
            Issue.record("Expected failure")
        } catch let error as GenerationProviderError {
            #expect(error == .httpStatus(429))
            #expect(error.localizedDescription.contains(secret) == false)
            #expect(String(describing: error).contains(secret) == false)
        }
    }

    @Test func uploadReferenceReturnsFileURLWithoutNetworking() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openai-media-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ref.png")
        try Data([0xFF]).write(to: file)

        let transport = FakeOpenAIMediaTransport { _ in
            Issue.record("uploadReference must not network")
            return try FakeOpenAIMediaTransport.http(status: 500, data: Data())
        }
        let provider = OpenAIMediaGenerationProvider(
            runtimeProfile: openAIMediaRuntime(),
            transport: transport
        )
        let ref = try await provider.uploadReference(fileURL: file, contentType: "image/png")
        #expect(ref == file.absoluteString)
        #expect(!ref.contains("base64"))
    }

    @Test func invalidImageResolutionBecomesAuto() async throws {
        let transport = FakeOpenAIMediaTransport { request in
            let body = try #require(request.httpBody)
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(object["size"] as? String == "auto")
            return try FakeOpenAIMediaTransport.jsonResponse([
                "data": [["url": "https://cdn.example/x.png"]],
            ])
        }
        let provider = OpenAIMediaGenerationProvider(
            runtimeProfile: openAIMediaRuntime(),
            transport: transport
        )
        _ = try await provider.start(request: GenerationProviderRequest(
            modelID: "gpt-image-2",
            params: .image(ImageGenerationParams(
                prompt: "x",
                aspectRatio: "1:1",
                resolution: "999x999",
                quality: nil,
                imageURLs: [],
                numImages: 1
            )),
            projectID: nil
        ))
    }

    @Test func startRejectsModelOutsideConfiguredAllowlist() async {
        let transport = FakeOpenAIMediaTransport { _ in
            Issue.record("must not network for allowlist rejection")
            return try FakeOpenAIMediaTransport.http(status: 500, data: Data())
        }
        let provider = OpenAIMediaGenerationProvider(
            runtimeProfile: openAIMediaRuntime(modelIDs: ["tts-1"]),
            transport: transport
        )
        do {
            _ = try await provider.start(request: GenerationProviderRequest(
                modelID: "gpt-image-2",
                params: .image(ImageGenerationParams(
                    prompt: "x",
                    aspectRatio: "1:1",
                    resolution: nil,
                    quality: nil,
                    imageURLs: [],
                    numImages: 1
                )),
                projectID: nil
            ))
            Issue.record("expected unsupported model")
        } catch let error as GenerationProviderError {
            #expect(error == .unsupported("gpt-image-2"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func pollRejectsDifferentPortWhenCredentialRedirectsDisabled() async {
        let transport = FakeOpenAIMediaTransport { _ in
            Issue.record("must not poll cross-origin credential URL")
            return try FakeOpenAIMediaTransport.http(status: 500, data: Data())
        }
        let runtime = openAIMediaRuntime(allowCredentialRedirects: false)
        let provider = OpenAIMediaGenerationProvider(runtimeProfile: runtime, transport: transport)
        let handle = GenerationJobHandle(
            providerProfileID: runtime.profile.id,
            providerKind: .openAIMedia,
            remoteID: "video_port",
            statusURL: "https://api.openai.com:8443/v1/videos/video_port",
            responseURL: "https://api.openai.com:8443/v1/videos/video_port/content",
            metadata: ["modelID": .string("sora-2")]
        )
        do {
            for try await _ in provider.updates(for: handle) {}
            Issue.record("expected invalid handle url")
        } catch let error as GenerationProviderError {
            #expect(error == .invalidResponse("handle url"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func pollRejectsDifferentSchemeWhenCredentialRedirectsDisabled() async {
        let transport = FakeOpenAIMediaTransport { _ in
            Issue.record("must not poll cross-origin credential URL")
            return try FakeOpenAIMediaTransport.http(status: 500, data: Data())
        }
        let runtime = openAIMediaRuntime(allowCredentialRedirects: false)
        let provider = OpenAIMediaGenerationProvider(runtimeProfile: runtime, transport: transport)
        let handle = GenerationJobHandle(
            providerProfileID: runtime.profile.id,
            providerKind: .openAIMedia,
            remoteID: "video_scheme",
            statusURL: "http://api.openai.com/v1/videos/video_scheme",
            responseURL: "http://api.openai.com/v1/videos/video_scheme/content",
            metadata: ["modelID": .string("sora-2")]
        )
        do {
            for try await _ in provider.updates(for: handle) {}
            Issue.record("expected invalid handle url")
        } catch let error as GenerationProviderError {
            #expect(error == .invalidResponse("handle url"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func pollAllowsDifferentPortWhenCredentialRedirectsEnabled() async throws {
        let mp4 = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70])
        let transport = FakeOpenAIMediaTransport { request in
            let path = try #require(request.url?.absoluteString)
            #expect(path.hasPrefix("https://api.openai.com:8443/"))
            if path.hasSuffix("/videos/video_ok") {
                return try FakeOpenAIMediaTransport.jsonResponse([
                    "id": "video_ok",
                    "status": "completed",
                    "progress": 100,
                ])
            }
            if path.hasSuffix("/videos/video_ok/content") {
                return try FakeOpenAIMediaTransport.http(status: 200, data: mp4)
            }
            Issue.record("Unexpected URL \(path)")
            return try FakeOpenAIMediaTransport.http(status: 404, data: Data())
        }
        let runtime = openAIMediaRuntime(
            options: ["timeoutSeconds": .number(60)],
            allowCredentialRedirects: true
        )
        let provider = OpenAIMediaGenerationProvider(runtimeProfile: runtime, transport: transport)
        let handle = GenerationJobHandle(
            providerProfileID: runtime.profile.id,
            providerKind: .openAIMedia,
            remoteID: "video_ok",
            statusURL: "https://api.openai.com:8443/v1/videos/video_ok",
            responseURL: "https://api.openai.com:8443/v1/videos/video_ok/content",
            metadata: ["modelID": .string("sora-2")]
        )

        var updates: [GenerationProviderUpdate] = []
        for try await update in provider.updates(for: handle) {
            updates.append(update)
            if case .succeeded = update { break }
        }
        guard case .succeeded(let artifacts) = updates.last,
              case .data(let data, let ext) = artifacts.first else {
            Issue.record("Expected succeeded mp4 artifact")
            return
        }
        #expect(data == mp4)
        #expect(ext == "mp4")
    }
}

// MARK: - Helpers

private func openAIMediaProfile(
    modelIDs: [String],
    options: [String: JSONValue] = [:],
    allowCredentialRedirects: Bool = false
) -> AIProviderProfile {
    AIProviderProfile(
        name: "OpenAI Media",
        baseURL: "https://api.openai.com/v1",
        allowCredentialRedirects: allowCredentialRedirects,
        auth: ProviderAuthConfiguration(kind: .bearer),
        generation: GenerationEndpointConfiguration(
            providerKind: .openAIMedia,
            modelIDs: modelIDs,
            options: options
        )
    )
}

private func openAIMediaRuntime(
    modelIDs: [String] = [],
    options: [String: JSONValue] = [:],
    allowCredentialRedirects: Bool = false
) -> AIProviderRuntimeProfile {
    let profile = openAIMediaProfile(
        modelIDs: modelIDs,
        options: options,
        allowCredentialRedirects: allowCredentialRedirects
    )
    return AIProviderRuntimeProfile(
        profile: profile,
        primaryCredential: "test-key",
        headers: ["Authorization": "Bearer test-key"]
    )
}

private final class FakeOpenAIMediaTransport: AIHTTPTransporting, @unchecked Sendable {
    private let handler: @Sendable (URLRequest) async throws -> AIHTTPDataResponse

    init(handler: @escaping @Sendable (URLRequest) async throws -> AIHTTPDataResponse) {
        self.handler = handler
    }

    func data(for request: URLRequest, maxResponseBytes: Int) async throws -> AIHTTPDataResponse {
        try await handler(request)
    }

    func lines(for request: URLRequest) async throws -> AIHTTPLineResponse {
        throw GenerationProviderError.unsupported("lines")
    }

    static func http(status: Int, data: Data) throws -> AIHTTPDataResponse {
        guard let url = URL(string: "https://api.openai.com/v1"),
              let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: nil
              ) else {
            throw GenerationProviderError.invalidResponse("fake http")
        }
        return AIHTTPDataResponse(data: data, response: response)
    }

    static func jsonResponse(_ object: [String: Any]) throws -> AIHTTPDataResponse {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try http(status: 200, data: data)
    }
}
