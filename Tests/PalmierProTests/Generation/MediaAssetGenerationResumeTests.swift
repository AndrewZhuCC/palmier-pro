import Foundation
import Testing
@testable import PalmierPro

@Suite("MediaAsset generation resume seams")
@MainActor
struct MediaAssetGenerationResumeTests {
    @Test func canResumeWhenResultURLsPresent() {
        var input = GenerationInput(
            prompt: "test",
            model: "some-model",
            duration: 0,
            aspectRatio: "1:1"
        )
        input.resultURLs = ["https://example.com/out-0.jpg"]
        let asset = MediaAsset(
            url: URL(fileURLWithPath: "/tmp/placeholder.jpg"),
            type: .image,
            name: "gen",
            generationInput: input
        )
        #expect(asset.canResumeGeneration)
        #expect(asset.isRecoveringGeneration == false)
        asset.generationStatus = .failed("download interrupted")
        #expect(asset.isRecoveringGeneration)
    }

    @Test func canResumeWhenProviderJobPresent() {
        var input = GenerationInput(
            prompt: "test",
            model: "some-model",
            duration: 5,
            aspectRatio: "16:9"
        )
        input.providerJob = GenerationJobHandle(
            providerProfileID: AIProviderProfile.palmierManagedID,
            providerKind: .palmierManaged,
            remoteID: "job-1"
        )
        let asset = MediaAsset(
            url: URL(fileURLWithPath: "/tmp/placeholder.mp4"),
            type: .video,
            name: "gen",
            generationInput: input
        )
        asset.generationStatus = .generating
        #expect(asset.canResumeGeneration)
        #expect(asset.isRecoveringGeneration)
    }

    @Test func cannotResumeWithoutJobOrResults() {
        let input = GenerationInput(
            prompt: "test",
            model: "some-model",
            duration: 0,
            aspectRatio: "1:1"
        )
        let asset = MediaAsset(
            url: URL(fileURLWithPath: "/tmp/placeholder.jpg"),
            type: .image,
            name: "gen",
            generationInput: input
        )
        asset.generationStatus = .failed("boom")
        #expect(!asset.canResumeGeneration)
        #expect(!asset.isRecoveringGeneration)
    }

    @Test func restoresPendingDownloadURLFromResultURLsOnManifestReload() {
        var input = GenerationInput(
            prompt: "test",
            model: "some-model",
            duration: 0,
            aspectRatio: "1:1"
        )
        input.outputIndex = 1
        input.resultURLs = [
            "https://example.com/out-0.jpg",
            "https://example.com/out-1.jpg",
        ]
        var entry = MediaManifestEntry(
            id: "asset-1",
            name: "gen",
            type: .image,
            source: .external(absolutePath: "/tmp/placeholder.jpg"),
            duration: Defaults.imageDurationSeconds
        )
        entry.generationInput = input
        entry.generationStatus = MediaAsset.GenerationStatus.failed("network").serialized
        let asset = MediaAsset(
            entry: entry,
            resolvedURL: URL(fileURLWithPath: "/tmp/placeholder.jpg")
        )
        #expect(asset.canResumeGeneration)
        #expect(asset.pendingDownloadURL?.absoluteString == "https://example.com/out-1.jpg")
        if case .failed = asset.generationStatus {
            // Expected.
        } else {
            Issue.record("expected failed generation status")
        }
    }

    @Test func doesNotRestorePendingDownloadWhenOutputIndexMissing() {
        var input = GenerationInput(
            prompt: "test",
            model: "some-model",
            duration: 0,
            aspectRatio: "1:1"
        )
        input.outputIndex = 3
        input.resultURLs = ["https://example.com/out-0.jpg"]
        var entry = MediaManifestEntry(
            id: "asset-2",
            name: "gen",
            type: .image,
            source: .external(absolutePath: "/tmp/placeholder.jpg"),
            duration: Defaults.imageDurationSeconds
        )
        entry.generationInput = input
        entry.generationStatus = MediaAsset.GenerationStatus.downloading.serialized
        let asset = MediaAsset(
            entry: entry,
            resolvedURL: URL(fileURLWithPath: "/tmp/placeholder.jpg")
        )
        #expect(asset.canResumeGeneration)
        #expect(asset.pendingDownloadURL == nil)
        #expect(asset.generationStatus == .downloading)
    }

    @Test func signedUploadCacheIsNotPersistedOrReused() {
        let providerID = UUID()
        let asset = MediaAsset(
            url: URL(fileURLWithPath: "/tmp/reference.jpg"),
            type: .image,
            name: "reference"
        )
        asset.cachedRemoteURL = "https://cdn.example/reference.jpg?signature=secret"
        asset.cachedRemoteURLExpiresAt = Date().addingTimeInterval(600)
        asset.cachedRemoteProviderProfileID = providerID

        #expect(asset.freshRemoteURL(for: providerID) == nil)
        let entry = asset.toManifestEntry(projectURL: nil)
        #expect(entry.cachedRemoteURL == nil)
        #expect(entry.cachedRemoteURLExpiresAt == nil)
        #expect(entry.cachedRemoteProviderProfileID == nil)
    }

    @Test func unsignedUploadCacheRemainsProviderScoped() {
        let providerID = UUID()
        let asset = MediaAsset(
            url: URL(fileURLWithPath: "/tmp/reference.jpg"),
            type: .image,
            name: "reference"
        )
        asset.cachedRemoteURL = "https://cdn.example/reference.jpg"
        asset.cachedRemoteURLExpiresAt = Date().addingTimeInterval(600)
        asset.cachedRemoteProviderProfileID = providerID

        #expect(asset.freshRemoteURL(for: providerID) == "https://cdn.example/reference.jpg")
        #expect(asset.freshRemoteURL(for: UUID()) == nil)
        let entry = asset.toManifestEntry(projectURL: nil)
        #expect(entry.cachedRemoteURL == "https://cdn.example/reference.jpg")
        #expect(entry.cachedRemoteProviderProfileID == providerID)
    }
}
