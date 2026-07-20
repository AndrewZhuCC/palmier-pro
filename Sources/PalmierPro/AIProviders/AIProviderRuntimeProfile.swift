import Foundation

enum AIProviderRuntimeError: LocalizedError, Equatable {
    case credentialMissing
    case secretHeaderMissing(String)

    var errorDescription: String? {
        switch self {
        case .credentialMissing: "The selected provider is missing its API key."
        case .secretHeaderMissing(let name): "The selected provider is missing secret header '\(name)'."
        }
    }
}

extension AIProviderRuntimeProfile {
    static func resolve(
        profile: AIProviderProfile,
        primaryCredential: String?,
        secretHeaderValues: [UUID: String]
    ) throws -> AIProviderRuntimeProfile {
        try AIProviderEndpoint.validate(profile)
        let trimmedCredential = primaryCredential?.trimmingCharacters(in: .whitespacesAndNewlines)
        if profile.requiresPrimaryCredential, trimmedCredential?.isEmpty != false {
            throw AIProviderRuntimeError.credentialMissing
        }
        if let trimmedCredential {
            try AIProviderEndpoint.validateHeaderValue(trimmedCredential, name: "credential")
        }

        var resolvedHeaders: [String: String] = [:]
        for header in profile.headers {
            if header.isSecret {
                guard let value = secretHeaderValues[header.id],
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AIProviderRuntimeError.secretHeaderMissing(header.name)
                }
                try AIProviderEndpoint.validateHeaderValue(value, name: header.name)
                resolvedHeaders[header.name] = value
            } else if let value = header.value {
                try AIProviderEndpoint.validateHeaderValue(value, name: header.name)
                resolvedHeaders[header.name] = value
            }
        }

        if let trimmedCredential, !trimmedCredential.isEmpty {
            switch profile.auth.kind {
            case .bearer:
                let prefix = profile.auth.valuePrefix ?? "Bearer "
                let headerValue = prefix + trimmedCredential
                try AIProviderEndpoint.validateHeaderValue(headerValue, name: "Authorization")
                resolvedHeaders["Authorization"] = headerValue
            case .xAPIKey:
                let prefix = profile.auth.valuePrefix ?? ""
                let headerValue = prefix + trimmedCredential
                try AIProviderEndpoint.validateHeaderValue(headerValue, name: "x-api-key")
                resolvedHeaders["x-api-key"] = headerValue
            case .customHeader:
                if let headerName = profile.auth.headerName {
                    let headerValue = (profile.auth.valuePrefix ?? "") + trimmedCredential
                    try AIProviderEndpoint.validateHeaderValue(headerValue, name: headerName)
                    resolvedHeaders[headerName] = headerValue
                }
            case .none, .palmierManaged:
                break
            }
        }

        return AIProviderRuntimeProfile(
            profile: profile,
            primaryCredential: trimmedCredential,
            headers: resolvedHeaders
        )
    }
}
