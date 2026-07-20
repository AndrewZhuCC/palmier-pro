import Foundation
@preconcurrency import Combine

struct PalmierGenerationProvider: GenerationProvider {
    let runtimeProfile: AIProviderRuntimeProfile

    func uploadReference(fileURL: URL, contentType: String) async throws -> String {
        try await GenerationBackend.uploadReference(fileURL: fileURL, contentType: contentType)
    }

    func start(request: GenerationProviderRequest) async throws -> GenerationProviderStart {
        let remoteID = try await GenerationBackend.submit(
            model: request.modelID,
            params: request.params,
            projectId: request.projectID
        )
        return .job(GenerationJobHandle(
            providerProfileID: runtimeProfile.profile.id,
            providerKind: .palmierManaged,
            remoteID: remoteID
        ))
    }

    func updates(for handle: GenerationJobHandle) -> AsyncThrowingStream<GenerationProviderUpdate, Error> {
        enum BridgeEvent {
            case job(BackendGenerationJob?)
            case failed(String)
        }

        let profileID = runtimeProfile.profile.id
        let (bridge, bridgeContinuation) = AsyncStream.makeStream(of: BridgeEvent.self)
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                guard handle.providerProfileID == profileID,
                      handle.providerKind == .palmierManaged else {
                    continuation.finish(throwing: GenerationProviderError.providerMismatch)
                    return
                }
                guard let publisher = GenerationBackend.subscribe(jobId: handle.remoteID) else {
                    continuation.finish(throwing: GenerationProviderError.missingGenerationService)
                    return
                }

                let cancellable = publisher
                    .receive(on: DispatchQueue.main)
                    .sink(
                        receiveCompletion: { completion in
                            switch completion {
                            case .finished:
                                bridgeContinuation.finish()
                            case .failure(let error):
                                bridgeContinuation.yield(.failed(error.localizedDescription))
                                bridgeContinuation.finish()
                            }
                        },
                        receiveValue: { job in
                            bridgeContinuation.yield(.job(job))
                        }
                    )
                defer { cancellable.cancel() }

                do {
                    for await event in bridge {
                        try Task.checkCancellation()
                        switch event {
                        case .failed(let message):
                            continuation.finish(
                                throwing: GenerationProviderError.transport(message)
                            )
                            return
                        case .job(let job):
                            guard let job else { continue }
                            switch job.status {
                            case .queued:
                                continuation.yield(.queued)
                            case .running:
                                continuation.yield(.running(progress: nil))
                            case .succeeded:
                                let artifacts = (job.resultUrls ?? []).compactMap(URL.init(string:)).map {
                                    GenerationArtifact.remoteURL($0)
                                }
                                continuation.yield(.succeeded(artifacts))
                                continuation.finish()
                                return
                            case .failed:
                                continuation.yield(.failed(code: "palmier_backend"))
                                continuation.finish()
                                return
                            }
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                bridgeContinuation.finish()
            }
        }
    }
}
