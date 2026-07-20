import Foundation

enum AIProviderConfigurationError: LocalizedError, Equatable {
    case emptyName
    case missingService
    case invalidManagedProfile
    case invalidBaseURL
    case unsupportedScheme(String)
    case missingHost
    case insecureHTTPRequiresConsent
    case invalidEndpointPath
    case missingModel
    case invalidMaxOutputTokens
    case invalidHeaderName(String)
    case invalidHeaderValue(String)
    case protectedHeader(String)
    case duplicateHeader(String)
    case secretHeaderContainsPersistedValue(String)
    case missingCustomAuthHeader
    case reservedBodyKey(String)

    var errorDescription: String? {
        switch self {
        case .emptyName: "Provider name cannot be empty."
        case .missingService: "Configure at least one Agent or Generation service."
        case .invalidManagedProfile: "Palmier-managed profiles must use the built-in Palmier identity and protocols."
        case .invalidBaseURL: "Enter a valid provider Base URL."
        case .unsupportedScheme(let scheme): "Unsupported URL scheme '\(scheme)'. Use HTTPS or explicitly allowed HTTP."
        case .missingHost: "Provider Base URL must include a host."
        case .insecureHTTPRequiresConsent: "Non-local HTTP requires explicit insecure-connection consent."
        case .invalidEndpointPath: "Endpoint path must be relative and cannot include a query or fragment."
        case .missingModel: "Agent default model cannot be empty."
        case .invalidMaxOutputTokens: "Max output tokens must be greater than zero."
        case .invalidHeaderName(let name): "Invalid HTTP header name '\(name)'."
        case .invalidHeaderValue(let name): "Header '\(name)' contains invalid control characters."
        case .protectedHeader(let name): "Header '\(name)' is managed by the app and cannot be overridden."
        case .duplicateHeader(let name): "Header '\(name)' is configured more than once."
        case .secretHeaderContainsPersistedValue(let name): "Secret header '\(name)' cannot persist its value in provider metadata."
        case .missingCustomAuthHeader: "Custom-header authentication requires a header name."
        case .reservedBodyKey(let key): "Additional request parameter '\(key)' is reserved by the protocol adapter."
        }
    }
}

enum AIProviderEndpoint {
    private static let protectedHeaders: Set<String> = [
        "authorization", "content-length", "content-type", "host", "transfer-encoding",
        "x-api-key", "anthropic-version",
    ]

    /// Structural / adapter headers that custom-header auth may never set.
    private static let structuralProtectedHeaders: Set<String> = [
        "content-length", "content-type", "host", "transfer-encoding", "anthropic-version",
    ]

    private static let commonReservedBodyKeys: Set<String> = [
        "input", "messages", "model", "stream", "store", "system", "tools",
    ]

    private static let maxEndpointPathDecodePasses = 8

    static func reservedBodyKeys(for wireProtocol: AgentWireProtocol) -> Set<String> {
        switch wireProtocol {
        case .openAIResponses:
            commonReservedBodyKeys.union(["instructions", "max_output_tokens"])
        case .openAIChatCompletions:
            commonReservedBodyKeys.union(["max_tokens", "stream_options"])
        case .anthropicMessages, .palmierManaged:
            commonReservedBodyKeys.union(["max_tokens"])
        }
    }

    static func validate(_ profile: AIProviderProfile) throws {
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderConfigurationError.emptyName
        }
        guard profile.agent != nil || profile.generation != nil else {
            throw AIProviderConfigurationError.missingService
        }
        try validateManagedProfile(profile)
        if !profile.isManagedPalmier {
            _ = try normalizedBaseURL(profile.baseURL, allowInsecureHTTP: profile.allowInsecureHTTP)
        }
        var seenHeaders = Set<String>()
        if profile.auth.kind == .customHeader {
            let header = profile.auth.headerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !header.isEmpty else { throw AIProviderConfigurationError.missingCustomAuthHeader }
            try validateHeaderName(header, allowAuthHeaders: true)
            seenHeaders.insert(header.lowercased())
        }
        if let valuePrefix = profile.auth.valuePrefix {
            try validateHeaderValue(valuePrefix, name: "authentication value prefix")
        }

        for header in profile.headers {
            let normalizedName = header.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            try validateHeaderName(header.name, allowAuthHeaders: false)
            guard seenHeaders.insert(normalizedName).inserted else {
                throw AIProviderConfigurationError.duplicateHeader(header.name)
            }
            if header.isSecret, header.value != nil {
                throw AIProviderConfigurationError.secretHeaderContainsPersistedValue(header.name)
            }
            if !header.isSecret, let value = header.value {
                try validateHeaderValue(value, name: header.name)
            }
        }

        if let agent = profile.agent {
            try validateEndpointPath(agent.endpointPath)
            guard !agent.defaultModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AIProviderConfigurationError.missingModel
            }
            guard agent.maxOutputTokens > 0 else {
                throw AIProviderConfigurationError.invalidMaxOutputTokens
            }
            let reserved = reservedBodyKeys(for: agent.wireProtocol)
            for key in agent.additionalBody.keys where reserved.contains(key.lowercased()) {
                throw AIProviderConfigurationError.reservedBodyKey(key)
            }
        }
        if let endpointPath = profile.generation?.endpointPath {
            try validateEndpointPath(endpointPath)
        }
    }

    private static func validateManagedProfile(_ profile: AIProviderProfile) throws {
        let hasManagedMarker = profile.id == AIProviderProfile.palmierManagedID
            || profile.auth.kind == .palmierManaged
            || profile.agent?.wireProtocol == .palmierManaged
            || profile.generation?.providerKind == .palmierManaged
        guard hasManagedMarker else { return }

        guard profile.id == AIProviderProfile.palmierManagedID,
              profile.auth.kind == .palmierManaged,
              profile.agent.map({ $0.wireProtocol == .palmierManaged }) ?? true,
              profile.generation.map({ $0.providerKind == .palmierManaged }) ?? true else {
            throw AIProviderConfigurationError.invalidManagedProfile
        }
    }

    static func normalizedBaseURL(_ rawValue: String, allowInsecureHTTP: Bool) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased() else {
            throw AIProviderConfigurationError.invalidBaseURL
        }
        guard scheme == "https" || scheme == "http" else {
            throw AIProviderConfigurationError.unsupportedScheme(scheme)
        }
        guard let host = components.host, !host.isEmpty else {
            throw AIProviderConfigurationError.missingHost
        }
        guard components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw AIProviderConfigurationError.invalidBaseURL
        }
        if scheme == "http", !isLoopbackHost(host), !allowInsecureHTTP {
            throw AIProviderConfigurationError.insecureHTTPRequiresConsent
        }

        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        components.scheme = scheme
        components.percentEncodedPath = path
        guard let url = components.url else { throw AIProviderConfigurationError.invalidBaseURL }
        return url
    }

    static func resolve(
        baseURL rawBaseURL: String,
        endpointPath: String,
        allowInsecureHTTP: Bool
    ) throws -> URL {
        let baseURL = try normalizedBaseURL(rawBaseURL, allowInsecureHTTP: allowInsecureHTTP)
        try validateEndpointPath(endpointPath)
        let trimmedEndpoint = endpointPath.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedEndpoint.isEmpty else { return baseURL }

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AIProviderConfigurationError.invalidBaseURL
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, trimmedEndpoint].filter { !$0.isEmpty }.joined(separator: "/")
        guard let resolved = components.url else { throw AIProviderConfigurationError.invalidEndpointPath }
        return resolved
    }

    static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        guard let firstComponents = URLComponents(url: first, resolvingAgainstBaseURL: false),
              let secondComponents = URLComponents(url: second, resolvingAgainstBaseURL: false) else {
            return false
        }
        return firstComponents.scheme?.lowercased() == secondComponents.scheme?.lowercased()
            && firstComponents.host?.lowercased() == secondComponents.host?.lowercased()
            && effectivePort(firstComponents) == effectivePort(secondComponents)
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        let value = host.lowercased()
        return value == "localhost" || value.hasSuffix(".localhost")
            || value == "::1" || value.hasPrefix("127.")
    }

    static func validateHeaderValue(_ value: String, name: String) throws {
        if containsDisallowedHeaderControlCharacters(value) {
            throw AIProviderConfigurationError.invalidHeaderValue(name)
        }
    }

    static func containsDisallowedHeaderControlCharacters(_ value: String) -> Bool {
        for scalar in value.unicodeScalars {
            let code = scalar.value
            if code == 0x7F { return true }
            if code <= 0x1F && code != 0x09 { return true }
        }
        return false
    }

    private static func validateEndpointPath(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try rejectUnsafeEndpointPath(trimmed)

        var current = trimmed
        for _ in 0..<maxEndpointPathDecodePasses {
            guard let decoded = current.removingPercentEncoding else {
                throw AIProviderConfigurationError.invalidEndpointPath
            }
            if decoded == current { return }
            try rejectUnsafeEndpointPath(decoded)
            current = decoded
        }

        if let decoded = current.removingPercentEncoding, decoded != current {
            throw AIProviderConfigurationError.invalidEndpointPath
        }
    }

    private static func rejectUnsafeEndpointPath(_ path: String) throws {
        if path.contains("\\") || path.contains("://") || path.contains("?") || path.contains("#") {
            throw AIProviderConfigurationError.invalidEndpointPath
        }
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            if segment == "." || segment == ".." {
                throw AIProviderConfigurationError.invalidEndpointPath
            }
        }
    }

    private static func validateHeaderName(_ rawName: String, allowAuthHeaders: Bool) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.unicodeScalars.allSatisfy(isHeaderTchar) else {
            throw AIProviderConfigurationError.invalidHeaderName(rawName)
        }
        let normalized = name.lowercased()
        if allowAuthHeaders {
            if structuralProtectedHeaders.contains(normalized) {
                throw AIProviderConfigurationError.protectedHeader(rawName)
            }
        } else if protectedHeaders.contains(normalized) {
            throw AIProviderConfigurationError.protectedHeader(rawName)
        }
    }

    /// RFC 7230 token / tchar: ASCII ALPHA / DIGIT / !#$%&'*+-.^_`|~
    private static func isHeaderTchar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x21, 0x23...0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x30...0x39,
             0x41...0x5A, 0x5E...0x7A, 0x7C, 0x7E:
            return true
        default:
            return false
        }
    }

    private static func effectivePort(_ components: URLComponents) -> Int? {
        if let port = components.port { return port }
        switch components.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}
