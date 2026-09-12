import Foundation

/// A persisted Relay identity. The bearer token is intentionally excluded and
/// stored in the Keychain under `deviceId` instead.
public struct DSHRemoteProfile: Codable, Sendable, Equatable {
    public let relayBaseURL: URL
    public let deviceId: String
    public let machineId: String
    public let machineName: String

    public init(relayBaseURL: URL, deviceId: String, machineId: String, machineName: String) {
        self.relayBaseURL = relayBaseURL
        self.deviceId = deviceId
        self.machineId = machineId
        self.machineName = machineName
    }
}

public enum DSHAPIError: Error, LocalizedError, Sendable, Equatable {
    case invalidServerURL
    case insecureRelayURL
    case invalidResponse
    case http(status: Int, message: String)
    case missingCredentials

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL: return "Enter a valid Relay address."
        case .insecureRelayURL: return "Relay addresses must use HTTPS (HTTP is allowed only for localhost testing)."
        case .invalidResponse: return "The Relay returned an invalid response."
        case .http(let status, let message): return "Relay error \(status): \(message)"
        case .missingCredentials: return "Pair this iPhone with a Mac first."
        }
    }
}

public final class DSHAPIClient: @unchecked Sendable {
    private let relayBaseURL: URL
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(relayBaseURL: URL, session: URLSession = .shared) {
        self.relayBaseURL = relayBaseURL
        self.session = session
    }

    /// A public Relay must be HTTPS. The narrow HTTP exception keeps local
    /// integration tests and a developer's localhost Relay practical.
    public static func relayBaseURL(from input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty else { throw DSHAPIError.invalidServerURL }
        if scheme == "http" {
            let localHosts = ["localhost", "127.0.0.1", "::1"]
            guard localHosts.contains(host.lowercased()) else { throw DSHAPIError.insecureRelayURL }
        } else if scheme != "https" {
            throw DSHAPIError.invalidServerURL
        }
        components.query = nil
        components.fragment = nil
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = path.isEmpty ? "" : "/\(path)"
        guard let url = components.url else { throw DSHAPIError.invalidServerURL }
        return url
    }

    public func pair(machineId: String, pairingSecret: String, deviceName: String) async throws -> (profile: DSHRemoteProfile, token: String) {
        let response: PairResponse = try await perform(
            method: "POST",
            path: ["v1", "pair"],
            body: PairRequest(machineId: machineId, pairingSecret: pairingSecret, deviceName: deviceName)
        )
        let profile = DSHRemoteProfile(relayBaseURL: relayBaseURL, deviceId: response.deviceId,
                                       machineId: machineId, machineName: response.machineName ?? machineId)
        return (profile, response.deviceToken)
    }

    private func perform<Body: Encodable, Value: Decodable>(method: String, path: [String], body: Body) async throws -> Value {
        var url = relayBaseURL
        for component in path { url.append(path: component) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DSHAPIError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            let serverError = try? decoder.decode(ServerError.self, from: data)
            throw DSHAPIError.http(status: http.statusCode,
                                   message: serverError?.message ?? serverError?.error ?? String(data: data, encoding: .utf8) ?? "Request failed")
        }
        do { return try decoder.decode(Value.self, from: data) }
        catch { throw DSHAPIError.invalidResponse }
    }
}

private struct PairRequest: Encodable {
    let machineId: String
    let pairingSecret: String
    let deviceName: String
}

private struct PairResponse: Decodable {
    let deviceId: String
    let deviceToken: String
    let machineName: String?
}

private struct ServerError: Decodable {
    let error: String?
    let message: String?
}
