import Foundation

/// The Macs this iPhone is paired with.
///
/// The app kept exactly one profile, so pairing a second Mac silently replaced
/// the first and a user with two Macs could never reach both. This stores an
/// ordered list plus the active machine, and folds the old single-profile key
/// into the list on first read so an existing install keeps its pairing.
///
/// Device tokens already live in the Keychain keyed by `deviceId`, so several
/// machines' credentials can coexist without further changes.
public struct DSHProfileStore: @unchecked Sendable {
    public static let profilesKey = "dsh-anywhere.relay-profiles"
    public static let activeMachineKey = "dsh-anywhere.active-machine-id"
    /// Written by the single-profile version; read once, for migration.
    public static let legacyProfileKey = "dsh-anywhere.relay-profile"

    // `UserDefaults` is documented as thread-safe; the unchecked conformance is
    // only needed because the type itself is not marked Sendable.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var profiles: [DSHRemoteProfile] { load() }

    public var activeMachineId: String? {
        defaults.string(forKey: Self.activeMachineKey) ?? load().first?.machineId
    }

    public var activeProfile: DSHRemoteProfile? {
        let all = load()
        guard let id = activeMachineId else { return all.first }
        return all.first { $0.machineId == id } ?? all.first
    }

    /// Adds or replaces one machine. Re-pairing the same Mac updates it in place
    /// instead of appending a duplicate.
    @discardableResult
    public func upsert(_ profile: DSHRemoteProfile, makeActive: Bool = true) -> [DSHRemoteProfile] {
        var all = load().filter { $0.machineId != profile.machineId }
        all.append(profile)
        save(all)
        if makeActive { setActive(profile.machineId) }
        return all
    }

    /// Removes one machine, moving the active selection to a remaining Mac so a
    /// removal can never leave the app pointing at nothing.
    @discardableResult
    public func remove(_ machineId: String) -> [DSHRemoteProfile] {
        let all = load().filter { $0.machineId != machineId }
        save(all)
        if activeMachineId == machineId {
            if let next = all.first { setActive(next.machineId) }
            else { defaults.removeObject(forKey: Self.activeMachineKey) }
        }
        return all
    }

    public func setActive(_ machineId: String) {
        defaults.set(machineId, forKey: Self.activeMachineKey)
    }

    private func load() -> [DSHRemoteProfile] {
        if let data = defaults.data(forKey: Self.profilesKey),
           let decoded = try? JSONDecoder().decode([DSHRemoteProfile].self, from: data) {
            return decoded
        }
        guard let legacy = defaults.data(forKey: Self.legacyProfileKey),
              let profile = try? JSONDecoder().decode(DSHRemoteProfile.self, from: legacy) else {
            return []
        }
        save([profile])
        setActive(profile.machineId)
        return [profile]
    }

    private func save(_ profiles: [DSHRemoteProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: Self.profilesKey)
    }
}
