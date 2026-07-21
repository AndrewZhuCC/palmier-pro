import Foundation

struct VideoEgressRenderContext: Sendable {
    var model: String
    var prompt: String
    var duration: Int
    var aspectRatio: String
    var resolution: String?
    var size: String?
    var startFrameURL: String?
    var referenceImageURLs: [String]
    var jobId: String?

    static func videoSize(resolution: String?, aspectRatio: String) -> String? {
        switch (resolution, aspectRatio) {
        case ("720p", "16:9"): return "1280x720"
        case ("720p", "9:16"): return "720x1280"
        case ("1080p", "16:9"): return "1920x1080"
        case ("1080p", "9:16"): return "1080x1920"
        case ("480p", "16:9"): return "854x480"
        case ("480p", "9:16"): return "480x854"
        default: return nil
        }
    }

    init(model: String, params: VideoGenerationParams, jobId: String? = nil) {
        self.model = model
        self.prompt = params.prompt
        self.duration = params.duration
        self.aspectRatio = params.aspectRatio
        self.resolution = params.resolution
        self.size = Self.videoSize(resolution: params.resolution, aspectRatio: params.aspectRatio)
        self.startFrameURL = Self.httpURLString(params.startFrameURL)
        self.referenceImageURLs = params.referenceImageURLs.compactMap(Self.httpURLString)
        self.jobId = jobId
    }

    private static func httpURLString(_ raw: String?) -> String? {
        guard let raw, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }
        return raw
    }
}

enum VideoEgressRenderer {
    private static let placeholderPattern = #"\{\{([^{}]+)\}\}"#

    static func renderString(
        _ template: String,
        context: VideoEgressRenderContext,
        allowMissingOptional: Bool = true
    ) throws -> String? {
        guard let regex = try? NSRegularExpression(pattern: placeholderPattern) else {
            throw GenerationProviderError.invalidResponse("videoProfile placeholder")
        }
        let ns = template as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: template, range: full)
        if matches.isEmpty { return template }

        var output = template
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let nameRange = Range(match.range(at: 1), in: output),
                  let tokenRange = Range(match.range(at: 0), in: output) else {
                continue
            }
            let name = String(output[nameRange])
            if name == "referenceImageURLs" {
                if allowMissingOptional {
                    output.replaceSubrange(tokenRange, with: "")
                    continue
                }
                throw GenerationProviderError.invalidResponse("videoProfile field referenceImageURLs")
            }
            if let value = try scalarValue(name: name, context: context) {
                output.replaceSubrange(tokenRange, with: value)
            } else if allowMissingOptional, isOptionalPlaceholder(name) {
                output.replaceSubrange(tokenRange, with: "")
            } else if name == "size" || name == "resolution" {
                return nil
            } else {
                throw GenerationProviderError.invalidResponse("videoProfile missing \(name)")
            }
        }
        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func renderJSON(_ value: JSONValue, context: VideoEgressRenderContext) throws -> JSONValue? {
        switch value {
        case .null, .bool, .number:
            return value
        case .string(let template):
            return try renderJSONString(template, context: context)
        case .array(let items):
            var out: [JSONValue] = []
            for item in items {
                if let rendered = try renderJSON(item, context: context) {
                    out.append(rendered)
                }
            }
            return .array(out)
        case .object(let object):
            var out: [String: JSONValue] = [:]
            for (key, child) in object {
                if let rendered = try renderJSON(child, context: context) {
                    out[key] = rendered
                }
            }
            return .object(out)
        }
    }

    static func renderCreateBody(
        required: JSONValue?,
        optional: JSONValue?,
        context: VideoEgressRenderContext
    ) throws -> JSONValue {
        var base: [String: JSONValue] = [:]
        if let required {
            guard let rendered = try renderJSON(required, context: context),
                  case .object(let object) = rendered else {
                throw GenerationProviderError.invalidResponse("videoProfile body must be object")
            }
            base = object
        }
        if let optional, case .object(let object) = optional {
            for (key, child) in object {
                guard let rendered = try renderJSON(child, context: context) else { continue }
                if case .string(let s) = rendered, s.isEmpty { continue }
                if case .array(let a) = rendered, a.isEmpty { continue }
                base[key] = rendered
            }
        }
        return .object(base)
    }

    static func renderMultipartFields(
        fields: [String: String],
        optional: JSONValue?,
        context: VideoEgressRenderContext
    ) throws -> [(String, String)] {
        var pairs: [(String, String)] = []
        for (name, template) in fields.sorted(by: { $0.key < $1.key }) {
            if let value = try renderString(template, context: context), !value.isEmpty {
                pairs.append((name, value))
                continue
            }
            if name == "size" { continue }
            throw GenerationProviderError.invalidResponse("videoProfile field \(name)")
        }
        if let optional, case .object(let object) = optional {
            for (name, child) in object.sorted(by: { $0.key < $1.key }) {
                guard case .string(let template) = child,
                      let value = try renderString(template, context: context),
                      !value.isEmpty else {
                    continue
                }
                pairs.append((name, value))
            }
        }
        return pairs
    }

    static func renderPath(_ template: String, context: VideoEgressRenderContext) throws -> String {
        guard let value = try renderString(template, context: context, allowMissingOptional: false),
              !value.isEmpty else {
            throw GenerationProviderError.invalidResponse("videoProfile path")
        }
        return value
    }

    static func value(atDotPath path: String, in root: JSONValue) -> JSONValue? {
        let parts = path.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return nil }
        var current = root
        for part in parts {
            guard case .object(let object) = current, let next = object[part] else {
                return nil
            }
            current = next
        }
        return current
    }

    static func string(atDotPath path: String, in root: JSONValue) -> String? {
        switch value(atDotPath: path, in: root) {
        case .string(let s)?:
            return s
        case .number(let n)?:
            return String(n)
        default:
            return nil
        }
    }

    // MARK: - Private

    private static func renderJSONString(
        _ template: String,
        context: VideoEgressRenderContext
    ) throws -> JSONValue? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "{{referenceImageURLs}}" {
            let urls = context.referenceImageURLs
            return urls.isEmpty ? nil : .array(urls.map(JSONValue.string))
        }
        if trimmed == "{{duration:int}}" {
            return .number(Double(context.duration))
        }
        if let only = singlePlaceholderName(trimmed) {
            if only == "duration:int" {
                return .number(Double(context.duration))
            }
            if let scalar = try scalarValue(name: only, context: context) {
                return .string(scalar)
            }
            return nil
        }
        guard let text = try renderString(template, context: context) else { return nil }
        return .string(text)
    }

    private static func singlePlaceholderName(_ template: String) -> String? {
        guard template.hasPrefix("{{"), template.hasSuffix("}}"), template.count > 4 else {
            return nil
        }
        let inner = String(template.dropFirst(2).dropLast(2))
        guard !inner.contains("{"), !inner.contains("}") else { return nil }
        return inner
    }

    private static func isOptionalPlaceholder(_ name: String) -> Bool {
        switch name {
        case "startFrameURL", "referenceImageURLs", "resolution", "size", "jobId":
            return true
        default:
            return false
        }
    }

    private static func scalarValue(
        name: String,
        context: VideoEgressRenderContext
    ) throws -> String? {
        switch name {
        case "model":
            return context.model
        case "prompt":
            return context.prompt
        case "duration", "duration:string", "duration:int":
            return String(context.duration)
        case "aspectRatio":
            return context.aspectRatio.isEmpty ? nil : context.aspectRatio
        case "resolution":
            return context.resolution
        case "size":
            return context.size
        case "startFrameURL":
            return context.startFrameURL
        case "jobId":
            return context.jobId
        case "referenceImageURLs":
            return nil
        default:
            throw GenerationProviderError.invalidResponse("videoProfile placeholder \(name)")
        }
    }
}
