import Foundation

enum VideoToAudioEditKind {
    case music
    case sfx

    var title: String {
        switch self {
        case .music: "Generate Music"
        case .sfx: "Generate SFX"
        }
    }

    var providerName: String {
        switch self {
        case .music: "Sonilo"
        case .sfx: "Mirelo"
        }
    }

    var action: EditAction {
        switch self {
        case .music: .generateMusic
        case .sfx: .generateSFX
        }
    }

    var iconName: String {
        switch self {
        case .music: "music.note"
        case .sfx: "waveform"
        }
    }

    var description: String {
        switch self {
        case .music: "Generate music that fits the video"
        case .sfx: "Create matching sound for the video"
        }
    }

    var timelineActionName: String {
        switch self {
        case .music: "Add Music"
        case .sfx: "Add Sound Effects"
        }
    }

    var preferredModelId: String {
        switch self {
        case .music: "sonilo-v1.1-video-to-music"
        case .sfx: "mirelo-sfx-v1.5-video-to-audio"
        }
    }

    var category: AudioModelConfig.Category {
        switch self {
        case .music: .music
        case .sfx: .sfx
        }
    }

    @MainActor
    var model: AudioModelConfig? {
        let candidates = AudioModelConfig.allModels.filter {
            $0.category == category
                && $0.inputs.contains(.video)
                && GenerationAccessPolicy.isAvailable(modelID: $0.id, paidOnly: $0.paidOnly)
        }
        if let preferred = candidates.first(where: { $0.id == preferredModelId }) {
            return preferred
        }
        if let named = candidates.first(where: {
            $0.id.localizedCaseInsensitiveContains(providerName)
                || $0.displayName.localizedCaseInsensitiveContains(providerName)
        }) {
            return named
        }
        return candidates.first
    }
}
