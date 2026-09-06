import Foundation

enum LibraryTests {
    static func run() {
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let later = first.addingTimeInterval(100)
        func device(_ address: String, name: String = "en5", registry: UInt64 = 1,
                    hardware: String = "00:11:22:33:44:55") -> NetworkDevice {
            .init(name: name, title: "USB LAN", kind: "Ethernet", address: address,
                  enabled: true, registryID: registry, hardwareAddress: hardware)
        }
        let initial = device("02:11:22:33:44:55")
        let changed = device("02:11:22:33:44:66", name: "en8", registry: 2)
        let other = device("02:11:22:33:44:77", hardware: "00:11:22:33:44:77")
        precondition(initial.historyKey == changed.historyKey && initial.id != changed.id)
        precondition(initial.historyKey != other.historyKey)
        var library = AddressLibrary()
        library.observe(initial, at: first)
        library.observe(changed, at: later)
        library.observe(other, at: first)
        let key = initial.historyKey
        precondition(library.devices.count == 2)
        precondition(library.devices[key]?.originalAddress == initial.address)
        precondition(library.devices[key]?.entries.count == 2)
        precondition(library.devices[other.historyKey]?.entries.count == 1)
        precondition(library.devices[key]?.sortedEntries.first?.address == initial.address)
        try! library.add("02-AA-BB-CC-DD-EE", note: "备用", to: key, at: first)
        try! library.add("02aabbccddee", note: "", to: key, at: later)
        precondition(library.devices[key]?.entries.count == 3)
        precondition(library.devices[key]?.entries["02:aa:bb:cc:dd:ee"]?.note == "备用")
        precondition(library.devices[key]?.entries["02:aa:bb:cc:dd:ee"]?.manuallyAdded == true)
        precondition(library.devices[key]?.entries["02:aa:bb:cc:dd:ee"]?.lastSeenAt == nil)
        library.recordApplied(changed, at: later)
        precondition(library.devices[key]?.entries[changed.address]?.lastAppliedAt == later)
        try! library.rename(initial.address, note: "最早记录", in: key)
        precondition(library.devices[key]?.originalAddress == initial.address)
        do {
            try library.remove(initial.address, from: key)
            preconditionFailure("Original address deletion was permitted")
        } catch {}
        do {
            try library.add("ff:ff:ff:ff:ff:ff", note: "bad", to: key)
            preconditionFailure("Invalid address accepted")
        } catch {}
        try! library.remove("02:aa:bb:cc:dd:ee", from: key)
        precondition(library.devices[key]?.entries.count == 2)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macswitch-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AddressLibraryStore(url: directory.appendingPathComponent("addresses.json"))
        precondition(try! store.load() == AddressLibrary())
        try! store.save(library)
        var reloaded = try! store.load()
        precondition(reloaded == library)
        reloaded.observe(device("02:11:22:33:44:88", registry: 77), at: later)
        precondition(reloaded.devices[key]?.originalAddress == initial.address)
        precondition(reloaded.devices[key]?.entries.count == 3)
        let before = try! Data(contentsOf: store.url!)
        var invalid = library
        invalid.version = 99
        do {
            try store.save(invalid)
            preconditionFailure("Unsupported schema was saved")
        } catch {}
        precondition(try! Data(contentsOf: store.url!) == before)
        let corrupt = Data("{broken json".utf8)
        try! corrupt.write(to: store.url!)
        do {
            _ = try store.load()
            preconditionFailure("Corrupt file was silently accepted")
        } catch {}
        precondition(try! Data(contentsOf: store.url!) == corrupt)
        let attributes = try! FileManager.default.attributesOfItem(atPath: store.url!.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        print("PASS: per-device history, reconnect identity, deduplication, notes, original protection, persistence and corrupt-file preservation.")
    }
}
