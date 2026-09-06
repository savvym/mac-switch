import Foundation

struct SavedAddress: Identifiable, Codable, Equatable {
    let address: String
    var note = ""
    var manuallyAdded = false
    let createdAt: Date
    var lastSeenAt: Date?
    var lastAppliedAt: Date?
    var id: String { address }
}

struct DeviceAddressList: Codable, Equatable {
    let key: String
    var title: String
    let originalAddress: String
    let createdAt: Date
    var entries: [String: SavedAddress]

    var sortedEntries: [SavedAddress] {
        entries.values.sorted {
            if ($0.address == originalAddress) != ($1.address == originalAddress) {
                return $0.address == originalAddress
            }
            let lhs = $0.lastAppliedAt ?? $0.lastSeenAt ?? $0.createdAt
            let rhs = $1.lastAppliedAt ?? $1.lastSeenAt ?? $1.createdAt
            if lhs != rhs { return lhs > rhs }
            return $0.address < $1.address
        }
    }
}

enum LibraryError: LocalizedError {
    case invalidAddress, missingDevice, protectedAddress, invalidFile
    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "MAC 地址格式无效。"
        case .missingDevice: return "设备地址列表不存在，请刷新。"
        case .protectedAddress: return "原始地址不能删除。"
        case .invalidFile: return "地址列表文件格式无效或版本不兼容，未覆盖原文件。"
        }
    }
}

struct AddressLibrary: Codable, Equatable {
    var version = 1
    var devices: [String: DeviceAddressList] = [:]

    mutating func observe(_ device: NetworkDevice, at date: Date = Date()) {
        guard let address = MACAddress.normalize(device.address) else { return }
        let key = device.historyKey
        if devices[key] == nil {
            devices[key] = .init(key: key, title: device.title, originalAddress: address,
                                 createdAt: date, entries: [:])
        }
        devices[key]?.title = device.title
        if devices[key]?.entries[address] == nil {
            devices[key]?.entries[address] = .init(address: address, createdAt: date)
        }
        devices[key]?.entries[address]?.lastSeenAt = date
    }

    mutating func add(_ input: String, note: String, to key: String, at date: Date = Date()) throws {
        guard let address = MACAddress.normalize(input) else { throw LibraryError.invalidAddress }
        guard devices[key] != nil else { throw LibraryError.missingDevice }
        var entry = devices[key]!.entries[address] ?? .init(address: address, createdAt: date)
        entry.manuallyAdded = true
        let trimmed = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        if !trimmed.isEmpty { entry.note = trimmed }
        devices[key]?.entries[address] = entry
    }

    mutating func rename(_ address: String, note: String, in key: String) throws {
        guard devices[key]?.entries[address] != nil else { throw LibraryError.missingDevice }
        devices[key]?.entries[address]?.note = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    }

    mutating func remove(_ address: String, from key: String) throws {
        guard let device = devices[key] else { throw LibraryError.missingDevice }
        guard address != device.originalAddress else { throw LibraryError.protectedAddress }
        devices[key]?.entries.removeValue(forKey: address)
    }

    mutating func recordApplied(_ device: NetworkDevice, at date: Date = Date()) {
        observe(device, at: date)
        if let address = MACAddress.normalize(device.address) {
            devices[device.historyKey]?.entries[address]?.lastAppliedAt = date
        }
    }

    func validate() throws {
        guard version == 1 else { throw LibraryError.invalidFile }
        for (key, device) in devices {
            guard key == device.key, device.entries[device.originalAddress] != nil else { throw LibraryError.invalidFile }
            for (address, entry) in device.entries {
                guard MACAddress.normalize(address) == address, entry.address == address,
                      entry.note.count <= 80 else { throw LibraryError.invalidFile }
            }
        }
    }
}

struct AddressLibraryStore {
    let url: URL?

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MACSwitch", isDirectory: true).appendingPathComponent("addresses.json")
    }

    func load() throws -> AddressLibrary {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return AddressLibrary() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let library = try decoder.decode(AddressLibrary.self, from: Data(contentsOf: url))
            try library.validate()
            return library
        } catch let error as CocoaError { throw error }
        catch { throw LibraryError.invalidFile }
    }

    func save(_ library: AddressLibrary) throws {
        try library.validate()
        guard let url else { return }
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(library).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
