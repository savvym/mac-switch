import Foundation
import Darwin

@main
enum PrivilegedHelper {
    static func fail(_ text: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data((text + "\n").utf8))
        exit(code)
    }

    static func main() {
        let args = CommandLine.arguments
        guard args.count == 6, ["--apply", "--apply-wifi", "--validate"].contains(args[1]),
              MACAddress.validDevice(args[2]),
              let target = MACAddress.normalize(args[3]),
              let identifier = UInt64(args[4]), identifier > 0,
              let expected = MACAddress.normalize(args[5]) else {
            fail("INVALID_INPUT: invalid device, address or registry identity.", code: 2)
        }
        let device = args[2]
        guard let current = NetworkInventory.read().first(where: { $0.name == device && $0.registryID == identifier }) else {
            fail("STALE_DEVICE: selected adapter has disconnected or changed.", code: 3)
        }
        guard current.address == expected else {
            fail("STALE_ADDRESS: current address has changed; refresh before retrying.", code: 4)
        }
        if args[1] == "--validate" {
            print("VALID: identity and address match. No changes made.")
            exit(0)
        }
        guard geteuid() == 0 else { fail("Permission denied: administrator authorization is required.", code: 5) }
        let result: CommandResult
        if args[1] == "--apply-wifi" {
            guard current.isWiFi else { fail("INVALID_INPUT: selected interface is not Wi-Fi.", code: 2) }
            result = WiFiRestart.change(device: device, address: target, execute: run,
                                        sameDevice: { NetworkInventory.read().contains { $0.name == device && $0.registryID == identifier } },
                                        pause: { Thread.sleep(forTimeInterval: 1) })
        } else {
            result = run("/sbin/ifconfig", [device, "ether", target])
        }
        if !result.output.isEmpty {
            let handle = result.status == 0 ? FileHandle.standardOutput : FileHandle.standardError
            handle.write(Data((result.output + "\n").utf8))
        }
        exit(result.status)
    }

    static func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return .init(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        } catch {
            return .init(status: 1, output: error.localizedDescription)
        }
    }
}
