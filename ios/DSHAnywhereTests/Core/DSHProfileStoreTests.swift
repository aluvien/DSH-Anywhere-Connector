import XCTest
@testable import DSHAnywhere

final class DSHProfileStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "dsh-profile-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func profile(_ machineId: String, name: String = "Mac") -> DSHRemoteProfile {
        DSHRemoteProfile(relayBaseURL: URL(string: "https://relay.example.com")!,
                         deviceId: "device-\(machineId)",
                         machineId: machineId,
                         machineName: name)
    }

    func testPairingASecondMachineKeepsTheFirst() {
        let store = DSHProfileStore(defaults: defaults)

        store.upsert(profile("mac-a", name: "Studio"))
        store.upsert(profile("mac-b", name: "Laptop"))

        // The single-profile version replaced the first Mac here, which made a
        // second Mac permanently unreachable.
        XCTAssertEqual(store.profiles.map(\.machineId), ["mac-a", "mac-b"])
        XCTAssertEqual(store.activeMachineId, "mac-b")
        XCTAssertEqual(store.activeProfile?.machineName, "Laptop")
    }

    func testRepairingTheSameMachineUpdatesInsteadOfDuplicating() {
        let store = DSHProfileStore(defaults: defaults)

        store.upsert(profile("mac-a", name: "Old name"))
        store.upsert(profile("mac-a", name: "New name"))

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles.first?.machineName, "New name")
    }

    func testRemovingTheActiveMachineFallsBackToARemainingOne() {
        let store = DSHProfileStore(defaults: defaults)
        store.upsert(profile("mac-a"))
        store.upsert(profile("mac-b"))
        XCTAssertEqual(store.activeMachineId, "mac-b")

        store.remove("mac-b")

        // Removing must never leave the app pointing at a machine it no longer
        // has credentials for.
        XCTAssertEqual(store.profiles.map(\.machineId), ["mac-a"])
        XCTAssertEqual(store.activeMachineId, "mac-a")

        store.remove("mac-a")
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNil(store.activeMachineId)
    }

    func testMigratesTheSingleProfileLayoutOnce() throws {
        let legacy = profile("mac-legacy", name: "Old install")
        defaults.set(try JSONEncoder().encode(legacy), forKey: DSHProfileStore.legacyProfileKey)

        let store = DSHProfileStore(defaults: defaults)

        XCTAssertEqual(store.profiles.map(\.machineId), ["mac-legacy"])
        XCTAssertEqual(store.activeMachineId, "mac-legacy")
        // The migration is written back, so later reads use the new layout.
        XCTAssertNotNil(defaults.data(forKey: DSHProfileStore.profilesKey))
    }

    func testSwitchingMachinesChangesOnlyTheActiveSelection() {
        let store = DSHProfileStore(defaults: defaults)
        store.upsert(profile("mac-a"))
        store.upsert(profile("mac-b"))

        store.setActive("mac-a")

        XCTAssertEqual(store.activeProfile?.machineId, "mac-a")
        XCTAssertEqual(store.profiles.count, 2)
    }
}
