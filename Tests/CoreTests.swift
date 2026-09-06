import Foundation

@main
enum CoreTests {
    static func main() {
        LibraryTests.run()
        let examples: [(String, String?)] = [
            ("02:11:22:33:44:55", "02:11:22:33:44:55"),
            (" C0-C7-DB-12-34-56\n", "c0:c7:db:12:34:56"),
            ("021122334455", "02:11:22:33:44:55"),
            ("00:11:22:33:44:55", "00:11:22:33:44:55"),
            ("ff:ff:ff:ff:ff:ff", nil), ("01:11:22:33:44:55", nil),
            ("00:00:00:00:00:00", nil), ("", nil),
            ("02:11-22:33:44:55", nil), ("02:11:22:33:44:5g", nil),
            ("02:11:22:33:44:55;id", nil), ("02:11:22:33:44:55\nwhoami", nil)
        ]
        for (input, expected) in examples {
            precondition(MACAddress.normalize(input) == expected, "Unexpected normalization: \(input)")
        }
        for _ in 0..<1000 {
            let address = MACAddress.random()
            precondition(MACAddress.normalize(address) == address)
            precondition(UInt8(address.prefix(2), radix: 16)! & 3 == 2)
        }
        precondition(MACAddress.validDevice("en5"))
        precondition(!MACAddress.validDevice("en5;id"))
        precondition(!MACAddress.validDevice("en5\n"))
        precondition(!MACAddress.validDevice("bridge0"))
        func script(_ device: String, _ address: String, path: String = "/tmp/Test App/Helper") -> String? {
            ChangeCommand.appleScript(device: device, address: address, registryID: 1234,
                                      expected: "00:11:22:33:44:55", helperPath: path)
        }
        precondition(script("en5;id", "02:11:22:33:44:55") == nil)
        precondition(script("en5", "$(id)") == nil)
        precondition(script("en5", "021122334455") == "do shell script \"'/tmp/Test App/Helper' '--apply' 'en5' '02:11:22:33:44:55' '1234' '00:11:22:33:44:55'\" with administrator privileges")
        precondition(script("en5", "021122334455", path: "/tmp/bad\npath") == nil)
        precondition(ChangeCommand.shellQuote("a'b") == "'a'\\''b'")
        precondition(ChangeCommand.failureMessage("STALE_DEVICE").contains("停止"))
        precondition(ChangeCommand.failureMessage("User canceled. (-128)").contains("取消"))
        precondition(ChangeCommand.failureMessage("SIOCSIFLLADDR: Operation not supported").contains("不支持"))
        precondition(ChangeCommand.failureMessage("Operation not permitted").contains("权限"))
        precondition(ChangeCommand.failureMessage("Can't assign requested address").contains("拒绝"))
        precondition(ChangeCommand.failureMessage("execution error: ifconfig: ioctl (SIOCAIFADDR): Can't assign requested address (1)").contains("拒绝"))
        precondition(ChangeCommand.failureMessage("interface en5 does not exist").contains("断开"))
        precondition(ChangeCommand.failureMessage("WIFI_RESTORE_FAILED").contains("手动打开"))
        precondition(ChangeCommand.appleScript(device: "en0", address: "021122334455", registryID: 42,
                                              expected: "00:11:22:33:44:55", helperPath: "/tmp/Helper",
                                              restartWiFi: true)!.contains("'--apply-wifi'"))
        func simulate(initiallyOn: Bool = true, failOff: Bool = false, failOnCount: Int = 0,
                      failChange: Bool = false, disconnect: Bool = false) -> (CommandResult, [String], Bool) {
            var powered = initiallyOn
            var present = true
            var failures = failOnCount
            var calls: [String] = []
            let result = WiFiRestart.change(device: "en0", address: "02:11:22:33:44:55", execute: { executable, arguments in
                if executable == "/sbin/ifconfig" {
                    precondition(arguments == ["en0", "ether", "02:11:22:33:44:55"])
                    calls.append("change")
                    return .init(status: failChange ? 1 : 0, output: failChange ? "Can't assign requested address" : "")
                }
                precondition(executable == "/usr/sbin/networksetup")
                if arguments[0] == "-getairportpower" {
                    return .init(status: 0, output: "Wi-Fi Power (en0): \(powered ? "On" : "Off")\n")
                }
                let turnOn = arguments[2] == "on"
                calls.append(turnOn ? "on" : "off")
                if turnOn && failures > 0 {
                    failures -= 1
                    return .init(status: 1, output: "simulated power-on failure")
                }
                if !turnOn && failOff { return .init(status: 1, output: "simulated power-off failure") }
                powered = turnOn
                return .init(status: 0, output: "")
            }, sameDevice: { present }, pause: { if disconnect { present = false } })
            return (result, calls, powered)
        }
        let normal = simulate()
        precondition(normal.0.status == 0 && normal.1 == ["off", "on", "change"] && normal.2)
        let rejected = simulate(failChange: true)
        precondition(rejected.0.status == 1 && rejected.2)
        let offAlready = simulate(initiallyOn: false)
        precondition(offAlready.0.output.contains("WIFI_IS_OFF") && offAlready.1.isEmpty && !offAlready.2)
        let offFailed = simulate(failOff: true)
        precondition(offFailed.0.status != 0 && offFailed.1 == ["off"] && offFailed.2)
        let recovered = simulate(failOnCount: 1)
        precondition(recovered.0.status != 0 && recovered.1 == ["off", "on", "on"] && recovered.2)
        let recoveryFailed = simulate(failOnCount: 2)
        precondition(recoveryFailed.0.output.contains("WIFI_RESTORE_FAILED") && !recoveryFailed.2)
        let disconnected = simulate(disconnect: true)
        precondition(disconnected.0.output.contains("STALE_DEVICE") && disconnected.1 == ["off"])
        print("PASS: simulated Wi-Fi restart, address rejection, disabled radio, power failures, recovery and device replacement. No real radio commands executed.")
        let devices = NetworkInventory.read()
        precondition(Set(devices.map(\.id)).count == devices.count)
        precondition(devices.allSatisfy { MACAddress.validDevice($0.name) && $0.registryID != 0 })
        print("PASS: validation, 1000 random MACs, command injection checks, error mapping, read-only inventory (\(devices.count) interfaces).")
        if CommandLine.arguments.count == 2, let device = devices.first {
            let helper = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
            func validate(name: String, registryID: UInt64, expected: String) -> CommandResult {
                let process = Process()
                process.executableURL = helper
                process.arguments = ["--validate", name, "02:11:22:33:44:55", String(registryID), expected]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                try! process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return .init(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
            }
            let valid = validate(name: device.name, registryID: device.registryID, expected: device.address)
            precondition(valid.status == 0 && valid.output.contains("No changes made"))
            precondition(validate(name: device.name, registryID: UInt64.max, expected: device.address).status == 3)
            let other = device.address == "02:11:22:33:44:55" ? "02:11:22:33:44:56" : "02:11:22:33:44:55"
            precondition(validate(name: device.name, registryID: device.registryID, expected: other).status == 4)
            precondition(validate(name: "en5;id", registryID: device.registryID, expected: device.address).status == 2)
            print("PASS: helper read-only validation, disconnected/replaced device, changed address, invalid input.")
        }
    }
}
