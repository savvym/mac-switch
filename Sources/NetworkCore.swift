import Foundation
import Darwin
import SystemConfiguration
import IOKit

enum MACAddress {
    static func normalize(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pattern = "^(?:[0-9a-f]{12}|(?:[0-9a-f]{2}:){5}[0-9a-f]{2}|(?:[0-9a-f]{2}-){5}[0-9a-f]{2})$"
        guard text.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let hex = text.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
        let chars = Array(hex)
        let pairs = stride(from: 0, to: 12, by: 2).map { String(chars[$0...($0 + 1)]) }
        guard let first = UInt8(pairs[0], radix: 16), first & 1 == 0,
              pairs.contains(where: { $0 != "00" }) else { return nil }
        return pairs.joined(separator: ":")
    }

    static func random() -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] | 2) & 0xfe
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    static func validDevice(_ device: String) -> Bool {
        device.range(of: "^en[0-9]+$", options: .regularExpression) != nil
    }
}

struct NetworkDevice: Identifiable, Equatable, Codable, Sendable {
    let name: String
    let title: String
    let kind: String
    let address: String
    let enabled: Bool
    let registryID: UInt64
    var hardwareAddress: String? = nil
    var id: String { "\(name):\(registryID)" }
    var isWiFi: Bool { kind == "IEEE80211" }
    var historyKey: String {
        if let hardwareAddress, let mac = MACAddress.normalize(hardwareAddress) {
            return "hardware:\(kind):\(mac)"
        }
        return "session:\(NetworkInventory.sessionID):\(id)"
    }
    var displayName: String { title.contains("(\(name))") ? title : "\(title) (\(name))" }
}

enum NetworkInventory {
    static let sessionID = UUID().uuidString
    static func read() -> [NetworkDevice] {
        let interfaces = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? []
        let addresses = liveAddresses()
        let identifiers = registryIdentifiers()
        var seen = Set<String>()
        return interfaces.compactMap { interface -> NetworkDevice? in
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                  MACAddress.validDevice(name), seen.insert(name).inserted,
                  let live = addresses[name],
                  let registryID = identifiers[name] else { return nil }
            let kind = SCNetworkInterfaceGetInterfaceType(interface) as String? ?? "Ethernet"
            let title = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? name
            return NetworkDevice(name: name, title: title, kind: kind,
                                 address: live.0, enabled: live.1, registryID: registryID,
                                 hardwareAddress: SCNetworkInterfaceGetHardwareAddressString(interface) as String?)
        }.sorted {
            func rank(_ device: NetworkDevice) -> Int {
                if device.title.lowercased().contains("thunderbolt") { return 2 }
                return device.isWiFi ? 1 : 0
            }
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func liveAddresses() -> [String: (String, Bool)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }
        var result: [String: (String, Bool)] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cursor {
            let item = pointer.pointee
            cursor = item.ifa_next
            guard let address = item.ifa_addr, Int32(address.pointee.sa_family) == AF_LINK else { continue }
            let raw = UnsafeRawPointer(address)
            let link = raw.assumingMemoryBound(to: sockaddr_dl.self).pointee
            // sockaddr_dl stores the MAC immediately after its variable-length interface name.
            let offset = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data)! + Int(link.sdl_nlen)
            guard link.sdl_alen == 6, Int(link.sdl_len) >= offset + 6 else { continue }
            let bytes = raw.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            let mac = (0..<6).map { String(format: "%02x", bytes[$0]) }.joined(separator: ":")
            result[String(cString: item.ifa_name)] = (mac, item.ifa_flags & UInt32(IFF_UP) != 0)
        }
        return result
    }

    private static func registryIdentifiers() -> [String: UInt64] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IONetworkInterface"), &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        var result: [String: UInt64] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let name = IORegistryEntryCreateCFProperty(service, "BSD Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else { continue }
            var identifier: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS {
                result[name] = identifier
            }
        }
        return result
    }

    static let demo: [NetworkDevice] = [
        .init(name: "en5", title: "USB 10/100/1000 LAN", kind: "Ethernet", address: "02:16:3e:25:7a:90", enabled: true, registryID: 12345, hardwareAddress: "00:16:3e:25:7a:90"),
        .init(name: "en0", title: "Wi-Fi", kind: "IEEE80211", address: "c0:c7:db:12:34:56", enabled: true, registryID: 12346, hardwareAddress: "c0:c7:db:12:34:56")
    ]
}

struct CommandResult: Sendable {
    let status: Int32
    let output: String
}

enum WiFiRestart {
    // The injected command runner permits testing recovery without touching a real interface.
    static func change(device: String, address: String,
                       execute: (String, [String]) -> CommandResult,
                       sameDevice: () -> Bool, pause: () -> Void) -> CommandResult {
        func power() -> Bool? {
            let result = execute("/usr/sbin/networksetup", ["-getairportpower", device])
            guard result.status == 0 else { return nil }
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if output.hasSuffix(": On") { return true }
            if output.hasSuffix(": Off") { return false }
            return nil
        }
        func setPower(_ on: Bool) -> CommandResult {
            execute("/usr/sbin/networksetup", ["-setairportpower", device, on ? "on" : "off"])
        }
        func failure(_ tag: String, _ output: String = "") -> CommandResult {
            .init(status: 6, output: "\(tag)\n\(output)")
        }
        func recover(_ result: CommandResult) -> CommandResult {
            guard sameDevice() else { return failure("STALE_DEVICE", result.output) }
            if power() != true {
                let restored = setPower(true)
                if restored.status != 0 || power() != true {
                    return failure("WIFI_RESTORE_FAILED: turn Wi-Fi back on in System Settings.", result.output + "\n" + restored.output)
                }
            }
            return result
        }

        guard sameDevice() else { return failure("STALE_DEVICE") }
        guard let initiallyOn = power() else { return failure("WIFI_STATE_UNAVAILABLE") }
        guard initiallyOn else { return failure("WIFI_IS_OFF: turn Wi-Fi on before retrying.") }
        let off = setPower(false)
        guard off.status == 0, power() == false else { return recover(failure("WIFI_RESTART_FAILED", off.output)) }
        pause()
        guard sameDevice() else { return failure("STALE_DEVICE") }
        let on = setPower(true)
        guard on.status == 0, power() == true else { return recover(failure("WIFI_RESTART_FAILED", on.output)) }
        guard sameDevice() else { return failure("STALE_DEVICE") }
        let result = execute("/sbin/ifconfig", [device, "ether", address])
        return recover(result)
    }
}

enum ChangeCommand {
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScript(device: String, address: String, registryID: UInt64,
                            expected: String, helperPath: String, restartWiFi: Bool = false) -> String? {
        guard MACAddress.validDevice(device), let mac = MACAddress.normalize(address),
              let before = MACAddress.normalize(expected), registryID > 0,
              helperPath.hasPrefix("/"), !helperPath.contains("\n") else { return nil }
        let command = [helperPath, restartWiFi ? "--apply-wifi" : "--apply", device, mac, String(registryID), before]
            .map(shellQuote).joined(separator: " ")
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    static func run(script: String) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return .init(status: process.terminationStatus,
                         output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return .init(status: -1, output: error.localizedDescription)
        }
    }

    static func failureMessage(_ output: String) -> String {
        let text = output.lowercased()
        if text.contains("wifi_restore_failed") {
            return "未能重新打开 Wi-Fi，请在系统设置中手动打开。"
        }
        if text.contains("wifi_is_off") {
            return "Wi-Fi 当前已关闭，请先打开 Wi-Fi 再重试。"
        }
        if text.contains("wifi_state_unavailable") || text.contains("wifi_restart_failed") {
            return "无法完成 Wi-Fi 重启，已停止改址。请查看详细信息。"
        }
        if text.contains("stale_device") || text.contains("stale_address") {
            return "授权期间网卡或地址发生变化，已停止修改。请刷新后重试。"
        }
        if text.contains("-128") || text.contains("user canceled") || text.contains("user cancelled") {
            return "已取消管理员授权，未执行修改。"
        }
        if text.contains("operation not supported") || text.contains("not supported") {
            return "网卡或驱动不支持修改 MAC 地址。"
        }
        if text.contains("permission denied") || text.contains("operation not permitted") {
            return "系统拒绝修改：权限不足或驱动限制。"
        }
        if text.contains("can't assign requested address") || text.contains("invalid argument") {
            return "网卡拒绝了这个地址，可能是地址限制或当前接口状态不允许。"
        }
        if text.contains("does not exist") || text.contains("no such") {
            return "网卡已断开或接口不存在，请刷新设备列表。"
        }
        return "修改失败，请查看系统返回的详细信息。"
    }
}
