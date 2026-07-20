import Foundation
import Combine
@preconcurrency import ConvexMobile

enum ModelKind: Sendable {
    case video(VideoModelConfig)
    case image(ImageModelConfig)
    case audio(AudioModelConfig)
    case upscale(UpscaleModelConfig)

    var entry: CatalogEntry {
        switch self {
        case .video(let model): model.entry
        case .image(let model): model.entry
        case .audio(let model): model.entry
        case .upscale(let model): model.entry
        }
    }
}

enum ModelRegistry {
    @MainActor static var byId: [String: ModelKind] { ModelCatalog.shared.byId }

    @MainActor static func exists(id: String) -> Bool { byId[id] != nil }

    @MainActor static func entry(for id: String) -> CatalogEntry? { byId[id]?.entry }

    @MainActor static func displayName(for id: String) -> String {
        switch byId[id] {
        case .video(let m): m.displayName
        case .image(let m): m.displayName
        case .audio(let m): m.displayName
        case .upscale(let m): m.displayName
        case .none: id
        }
    }
}

@Observable
@MainActor
final class ModelCatalog {
    static let shared = ModelCatalog()

    private(set) var video: [VideoModelConfig] = []
    private(set) var image: [ImageModelConfig] = []
    private(set) var audio: [AudioModelConfig] = []
    private(set) var upscale: [UpscaleModelConfig] = []
    private(set) var byId: [String: ModelKind] = [:]
    private(set) var isLoaded: Bool = false
    private(set) var lastError: String?

    @ObservationIgnored private var subscription: AnyCancellable?
    @ObservationIgnored private var providerObserver: NSObjectProtocol?
    @ObservationIgnored private var didConfigure = false
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var failureCount = 0
    @ObservationIgnored private var managedEntries: [CatalogEntry] = []
    @ObservationIgnored private var externalEntries: [CatalogEntry] = []
    @ObservationIgnored private var managedLoaded = false
    @ObservationIgnored private var externalLoaded = false
    @ObservationIgnored private var managedError: String?
    @ObservationIgnored private var externalError: String?

    private init() {}

    func configure() {
        guard !didConfigure else { return }
        didConfigure = true
        providerObserver = NotificationCenter.default.addObserver(
            forName: .aiProviderConfigurationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.reloadExternalProviders()
            }
        }
        startSubscription()
        Task { await reloadExternalProviders() }
    }

    private func startSubscription() {
        guard let client = AccountService.shared.convex else {
            managedLoaded = true
            rebuildCatalog()
            return
        }

        subscription = client
            .subscribe(to: "models:list", yielding: [CatalogEntry].self)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let err) = completion {
                        self?.handleFailure(err)
                    }
                },
                receiveValue: { [weak self] entries in
                    guard let self else { return }
                    self.failureCount = 0
                    self.managedEntries = entries
                    self.managedLoaded = true
                    self.managedError = nil
                    self.rebuildCatalog()
                }
            )
    }

    private func handleFailure(_ err: ClientError) {
        failureCount += 1
        managedError = err.localizedDescription
        rebuildCatalog()
        if failureCount == 1 {
            Log.generation.error("ModelCatalog subscription failed: \(err.localizedDescription)")
        } else {
            Log.generation.warning("ModelCatalog subscription failed (attempt \(self.failureCount)): \(err.localizedDescription)")
        }
        let delay = min(pow(2.0, Double(failureCount - 1)), 60)
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.startSubscription()
        }
    }

    func reloadExternalProviders() async {
        var entries: [CatalogEntry] = []
        var errors: [String] = []

        for profile in AIProviderStore.shared.generationProfiles where !profile.isManagedPalmier {
            guard let configuration = profile.generation else { continue }
            do {
                switch configuration.providerKind {
                case .falQueue:
                    entries.append(contentsOf: FalGenerationCatalog.entries(profile: profile))
                case .openAIMedia:
                    entries.append(contentsOf: OpenAIMediaGenerationCatalog.entries(profile: profile))
                case .compatibleV1:
                    let runtime: AIProviderRuntimeProfile
                    if case .array? = configuration.options["models"] {
                        let publicHeaders: [String: String] = Dictionary(
                            uniqueKeysWithValues: profile.headers.compactMap { header -> (String, String)? in
                                guard !header.isSecret, let value = header.value else { return nil }
                                return (header.name, value)
                            }
                        )
                        runtime = AIProviderRuntimeProfile(
                            profile: profile,
                            primaryCredential: nil,
                            headers: publicHeaders
                        )
                    } else {
                        runtime = try await AIProviderStore.shared.runtimeProfile(id: profile.id)
                    }
                    entries.append(contentsOf: try await CompatibleGenerationCatalog.entries(
                        runtimeProfile: runtime
                    ))
                case .palmierManaged:
                    break
                }
            } catch {
                errors.append("\(profile.name): \(error.localizedDescription)")
            }
        }

        externalEntries = entries
        externalLoaded = true
        externalError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        rebuildCatalog()
    }

    private func rebuildCatalog() {
        var seen = Set<String>()
        let entries = (managedEntries + externalEntries).filter { seen.insert($0.id).inserted }
        var newVideo: [VideoModelConfig] = []
        var newImage: [ImageModelConfig] = []
        var newAudio: [AudioModelConfig] = []
        var newUpscale: [UpscaleModelConfig] = []
        var newById: [String: ModelKind] = [:]
        newVideo.reserveCapacity(entries.count)
        newImage.reserveCapacity(entries.count)
        newAudio.reserveCapacity(entries.count)
        newUpscale.reserveCapacity(entries.count)
        newById.reserveCapacity(entries.count)

        for entry in entries {
            switch entry.uiCapabilities {
            case .video(let caps):
                let model = VideoModelConfig(entry: entry, caps: caps)
                newVideo.append(model)
                newById[model.id] = .video(model)
            case .image(let caps):
                let model = ImageModelConfig(entry: entry, caps: caps)
                newImage.append(model)
                newById[model.id] = .image(model)
            case .audio(let caps):
                let model = AudioModelConfig(entry: entry, caps: caps)
                newAudio.append(model)
                newById[model.id] = .audio(model)
            case .upscale(let caps):
                let model = UpscaleModelConfig(entry: entry, caps: caps)
                newUpscale.append(model)
                newById[model.id] = .upscale(model)
            }
        }

        video = newVideo
        image = newImage
        audio = newAudio
        upscale = newUpscale
        byId = newById
        isLoaded = managedLoaded || externalLoaded
        lastError = [managedError, externalError].compactMap { $0 }.joined(separator: "\n")
        if lastError?.isEmpty == true { lastError = nil }
    }
}

struct CatalogEntry: Decodable, Sendable {
    let id: String
    let kind: Kind
    let displayName: String
    let allowedEndpoints: [String]
    let responseShape: ResponseShape
    let uiCapabilities: UICapabilities
    let creditsPerSecond: [String: Double]?
    let audioDiscountRate: [String: Double]?
    let creditsPerImage: [String: Double]?
    let qualities: [String]?
    let audioPricing: AudioPricing?
    let creditsPerSecondUpscale: Double?
    let paidOnly: Bool
    let providerProfileID: UUID?
    let providerKind: GenerationProviderKind?
    let providerModelID: String?

    enum Kind: String, Decodable, Sendable { case video, image, audio, upscale }
    enum ResponseShape: String, Decodable, Sendable {
        case video, images, audio, upscaledImage
    }

    enum UICapabilities: Sendable {
        case video(VideoCaps)
        case image(ImageCaps)
        case audio(AudioCaps)
        case upscale(UpscaleCaps)
    }

    enum AudioPricing: Decodable, Sendable {
        case perThousandChars(rate: Double)
        case perSecond(rate: Double)
        case flat(price: Double)

        private enum K: String, CodingKey { case mode, rate, price }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            switch try c.decode(String.self, forKey: .mode) {
            case "perThousandChars":
                self = .perThousandChars(rate: try c.decode(Double.self, forKey: .rate))
            case "perSecond":
                self = .perSecond(rate: try c.decode(Double.self, forKey: .rate))
            case "flat":
                self = .flat(price: try c.decode(Double.self, forKey: .price))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .mode, in: c,
                    debugDescription: "Unknown audio pricing mode"
                )
            }
        }
    }

    init(
        id: String,
        providerProfileID: UUID,
        providerKind: GenerationProviderKind,
        providerModelID: String,
        kind: Kind,
        displayName: String,
        responseShape: ResponseShape,
        uiCapabilities: UICapabilities,
        allowedEndpoints: [String] = [],
        creditsPerSecond: [String: Double]? = nil,
        audioDiscountRate: [String: Double]? = nil,
        creditsPerImage: [String: Double]? = nil,
        qualities: [String]? = nil,
        audioPricing: AudioPricing? = nil,
        creditsPerSecondUpscale: Double? = nil,
        paidOnly: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.allowedEndpoints = allowedEndpoints
        self.responseShape = responseShape
        self.uiCapabilities = uiCapabilities
        self.creditsPerSecond = creditsPerSecond
        self.audioDiscountRate = audioDiscountRate
        self.creditsPerImage = creditsPerImage
        self.qualities = qualities
        self.audioPricing = audioPricing
        self.creditsPerSecondUpscale = creditsPerSecondUpscale
        self.paidOnly = paidOnly
        self.providerProfileID = providerProfileID
        self.providerKind = providerKind
        self.providerModelID = providerModelID
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, displayName, allowedEndpoints, responseShape, uiCapabilities
        case creditsPerSecond, audioDiscountRate, creditsPerImage, qualities
        case audioPricing, creditsPerSecondUpscale, paidOnly
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.kind = try c.decode(Kind.self, forKey: .kind)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.allowedEndpoints = try c.decode([String].self, forKey: .allowedEndpoints)
        self.responseShape = try c.decode(ResponseShape.self, forKey: .responseShape)
        self.creditsPerSecond = try c.decodeIfPresent([String: Double].self, forKey: .creditsPerSecond)
        self.audioDiscountRate = try c.decodeIfPresent([String: Double].self, forKey: .audioDiscountRate)
        self.creditsPerImage = try c.decodeIfPresent([String: Double].self, forKey: .creditsPerImage)
        self.qualities = try c.decodeIfPresent([String].self, forKey: .qualities)
        self.audioPricing = try c.decodeIfPresent(AudioPricing.self, forKey: .audioPricing)
        self.creditsPerSecondUpscale = try c.decodeIfPresent(Double.self, forKey: .creditsPerSecondUpscale)
        self.paidOnly = try c.decodeIfPresent(Bool.self, forKey: .paidOnly) ?? false
        self.providerProfileID = AIProviderProfile.palmierManagedID
        self.providerKind = .palmierManaged
        self.providerModelID = self.id
        switch self.kind {
        case .video:
            self.uiCapabilities = .video(try c.decode(VideoCaps.self, forKey: .uiCapabilities))
        case .image:
            self.uiCapabilities = .image(try c.decode(ImageCaps.self, forKey: .uiCapabilities))
        case .audio:
            self.uiCapabilities = .audio(try c.decode(AudioCaps.self, forKey: .uiCapabilities))
        case .upscale:
            self.uiCapabilities = .upscale(try c.decode(UpscaleCaps.self, forKey: .uiCapabilities))
        }
    }
}

struct VideoCaps: Decodable, Sendable {
    let durations: [Int]
    let resolutions: [String]?
    let aspectRatios: [String]
    let supportsFirstFrame: Bool
    let supportsLastFrame: Bool
    let maxReferenceImages: Int
    let maxReferenceVideos: Int
    let maxReferenceAudios: Int
    let maxTotalReferences: Int?
    let maxCombinedVideoRefSeconds: Double?
    let maxCombinedAudioRefSeconds: Double?
    let framesAndReferencesExclusive: Bool
    let referenceTagNoun: String
    let requiresSourceVideo: Bool
    let requiresReferenceImage: Bool
}

struct ImageCaps: Decodable, Sendable {
    let resolutions: [String]?
    let aspectRatios: [String]
    let qualities: [String]?
    let supportsImageReference: Bool
    let maxImages: Int
}

struct AudioCaps: Decodable, Sendable {
    let category: String
    let voices: [String]?
    let defaultVoice: String?
    let supportsLyrics: Bool
    let supportsInstrumental: Bool
    let supportsStyleInstructions: Bool
    let durations: [Int]?
    let minPromptLength: Int
    let inputs: [String]?
    let promptLabel: String?
    let minSeconds: Int?
    let maxSeconds: Int?
    let targetLanguages: [String]?
    let defaultTargetLanguage: String?
}

struct UpscaleCaps: Decodable, Sendable {
    let speed: String   // "Fast" | "Medium" | "Slow"
    let p75DurationSeconds: Int
    let supportedTypes: [String]   // "video" | "image"
}
