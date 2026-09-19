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

    public func pair(machineId: String, credential: DSHPairingCredential, deviceName: String,
                     provisional: Bool = false) async throws -> (profile: DSHRemoteProfile, token: String) {
        let response: PairResponse = try await perform(
            method: "POST",
            path: ["v1", "pair"],
            body: PairRequest(machineId: machineId, credential: credential,
                              deviceName: deviceName, provisional: provisional)
        )
        let profile = DSHRemoteProfile(relayBaseURL: relayBaseURL, deviceId: response.deviceId,
                                       machineId: machineId, machineName: response.machineName ?? machineId)
        return (profile, response.deviceToken)
    }

    /// Devices paired to one machine. The Relay never returns credential
    /// material, so this carries identity and timestamps only.
    public func devices(machineId: String, token: String) async throws -> [DSHRelayDevice] {
        let response: DeviceListResponse = try await perform(
            method: "GET",
            path: ["v1", "machines", machineId, "devices"],
            bearerToken: token
        )
        return response.devices
    }

    public func revokeDevice(machineId: String, deviceId: String, token: String) async throws {
        let _: RevokeResponse = try await perform(
            method: "DELETE",
            path: ["v1", "machines", machineId, "devices", deviceId],
            bearerToken: token
        )
    }

    /// Compensates a just-completed pairing when the phone cannot commit its
    /// local profile/journal. This endpoint is deliberately separate from
    /// sibling device management, whose route refuses self-revocation.
    public func revokeSelfDevice(machineId: String, token: String) async throws {
        let _: RevokeResponse = try await perform(
            method: "DELETE",
            path: ["v1", "machines", machineId, "devices", "self"],
            bearerToken: token
        )
    }

    /// Activates a device created with the provisional pairing flow. The
    /// operation is idempotent, so a crash between the Relay response and the
    /// local marker cleanup can safely retry it on the next launch.
    public func activateSelfDevice(machineId: String, token: String) async throws {
        let _: ActivateResponse = try await perform(
            method: "POST",
            path: ["v1", "machines", machineId, "devices", "self", "activate"],
            bearerToken: token
        )
    }

    private func perform<Body: Encodable, Value: Decodable>(method: String, path: [String], body: Body) async throws -> Value {
        var request = makeRequest(method: method, path: path, bearerToken: nil)
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request)
    }

    private func perform<Value: Decodable>(method: String, path: [String], bearerToken: String) async throws -> Value {
        try await send(makeRequest(method: method, path: path, bearerToken: bearerToken))
    }

    private func makeRequest(method: String, path: [String], bearerToken: String?) -> URLRequest {
        var url = relayBaseURL
        for component in path { url.append(path: component) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send<Value: Decodable>(_ request: URLRequest) async throws -> Value {
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
    let pairingSecret: String?
    let pairingCode: String?
    let deviceName: String
    let provisional: Bool?

    /// Synthesized encoding omits nil optionals, so the Relay sees exactly one
    /// credential field rather than an empty one alongside the real value.
    init(machineId: String, credential: DSHPairingCredential, deviceName: String, provisional: Bool) {
        self.machineId = machineId
        self.deviceName = deviceName
        self.provisional = provisional ? true : nil
        switch credential {
        case .secret(let value): self.pairingSecret = value; self.pairingCode = nil
        case .code(let value): self.pairingSecret = nil; self.pairingCode = value
        }
    }
}

/// One device paired to a machine, as the Relay reports it. The Relay stores
/// only token hashes and never returns credential material here.
public struct DSHRelayDevice: Codable, Sendable, Equatable, Identifiable {
    public let deviceId: String
    public let name: String
    public let createdAt: Int64

    public var id: String { deviceId }

    public init(deviceId: String, name: String, createdAt: Int64) {
        self.deviceId = deviceId; self.name = name; self.createdAt = createdAt
    }
}

private struct DeviceListResponse: Decodable {
    let devices: [DSHRelayDevice]
}

private struct RevokeResponse: Decodable {
    let revoked: Bool?
    let deviceId: String?
}

private struct ActivateResponse: Decodable {
    let activated: Bool?
    let deviceId: String?
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
