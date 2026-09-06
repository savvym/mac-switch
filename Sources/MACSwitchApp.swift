import SwiftUI
import AppKit

@MainActor
final class SwitchModel: ObservableObject {
    @Published var devices: [NetworkDevice] = []
    @Published var selectedID = ""
    @Published var target = ""
    @Published var busy = false
    @Published var message = ""
    @Published var details = ""
    @Published var succeeded = false
    @Published var library = AddressLibrary()
    @Published var libraryError = ""
    @Published var confirmation = false
    @Published var restoring = false
    @Published var restartWiFi = false
    let demo = ProcessInfo.processInfo.arguments.contains("--demo")
    private let store: AddressLibraryStore
    private var loadFailed = false

    init() {
        let args = ProcessInfo.processInfo.arguments
        let demoIndex = args.firstIndex(of: "--demo-store")
        let demoURL = demoIndex.flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        store = AddressLibraryStore(url: demo ? demoURL : AddressLibraryStore.defaultURL)
        do { library = try store.load() }
        catch { libraryError = error.localizedDescription; loadFailed = true }
    }

    var selected: NetworkDevice? { devices.first { $0.id == selectedID } }
    var normalized: String? { MACAddress.normalize(target) }
    var addressList: DeviceAddressList? { selected.flatMap { library.devices[$0.historyKey] } }
    var original: String? { addressList?.originalAddress }
    var canApply: Bool {
        guard let device = selected, let normalized else { return false }
        return !busy && !loadFailed && normalized != device.address
    }
    var canRestore: Bool {
        guard let device = selected, let original else { return false }
        return !busy && !loadFailed && original != device.address
    }
    var proposedAddress: String { restoring ? original ?? "" : normalized ?? "" }

    @discardableResult
    private func updateLibrary(_ mutate: (inout AddressLibrary) throws -> Void) -> Bool {
        guard !loadFailed else { return false }
        do {
            var next = library
            try mutate(&next)
            try store.save(next)
            library = next
            libraryError = ""
            return true
        } catch {
            libraryError = "地址列表未保存：" + error.localizedDescription
            return false
        }
    }

    func addAddress(_ input: String, note: String) -> Bool {
        guard let device = selected, !busy else { return false }
        return updateLibrary { try $0.add(input, note: note, to: device.historyKey) }
    }

    func renameAddress(_ address: String, note: String) -> Bool {
        guard let device = selected, !busy else { return false }
        return updateLibrary { try $0.rename(address, note: note, in: device.historyKey) }
    }

    func deleteAddress(_ address: String) {
        guard let device = selected, !busy, address != device.address else { return }
        updateLibrary { try $0.remove(address, from: device.historyKey) }
    }

    func prepareAddress(_ address: String) {
        guard !busy, MACAddress.normalize(address) != nil else { return }
        target = address
        prepare(restore: false)
    }

    func refresh() {
        guard !busy else { return }
        devices = demo ? NetworkInventory.demo : NetworkInventory.read()
        updateLibrary { library in devices.forEach { library.observe($0) } }
        if selected == nil {
            selectedID = devices.first?.id ?? ""
        }
    }

    func selectionChanged() {
        target = selected?.address ?? ""
        restartWiFi = false
        message = ""
        details = ""
    }

    func prepare(restore: Bool) {
        restoring = restore
        confirmation = true
    }

    func apply() {
        guard let previous = selected,
              let mac = MACAddress.normalize(proposedAddress), !busy else { return }
        if demo {
            succeeded = false
            message = "演示模式：未执行网卡修改。"
            details = ""
            return
        }
        // A registry identity prevents restoring an old address onto a newly attached adapter.
        guard let current = NetworkInventory.read().first(where: { $0.id == previous.id }) else {
            succeeded = false
            message = "所选网卡已断开，请刷新后重新选择。"
            refresh()
            return
        }
        guard current.address != mac else {
            succeeded = true
            message = "当前地址已经是目标地址，无需修改。"
            refresh()
            return
        }
        guard updateLibrary({ $0.observe(current) }) else { return }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MACSwitchHelper").path
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            succeeded = false
            message = "应用文件不完整：找不到改址组件，请重新构建。"
            return
        }
        let shouldRestart = current.isWiFi && restartWiFi
        guard let script = ChangeCommand.appleScript(device: current.name, address: mac,
                                                     registryID: current.registryID,
                                                     expected: current.address, helperPath: helper,
                                                     restartWiFi: shouldRestart) else { return }
        busy = true
        succeeded = false
        details = ""
        message = "正在等待系统授权并修改…"
        Task {
            let result = await Task.detached { ChangeCommand.run(script: script) }.value
            message = "正在读取网卡地址并验证…"
            try? await Task.sleep(nanoseconds: current.isWiFi ? 3_000_000_000 : 1_000_000_000)
            let fresh = NetworkInventory.read()
            devices = fresh
            updateLibrary { library in fresh.forEach { library.observe($0) } }
            busy = false
            guard let actual = fresh.first(where: { $0.id == current.id }) else {
                message = "网卡已断开，无法验证修改结果。重新连接后请刷新。"
                details = result.output
                return
            }
            if actual.address == mac && result.status == 0 {
                updateLibrary { $0.recordApplied(actual) }
                succeeded = true
                message = "修改成功，已验证当前 MAC 地址。"
                target = mac
                details = result.status == 0 ? "" : result.output
            } else if result.status != 0 {
                message = ChangeCommand.failureMessage(result.output)
                if actual.address == mac {
                    message = "地址已改变，但流程未完整完成。" + message
                    target = mac
                } else if current.isWiFi && !shouldRestart && result.output.lowercased().contains("can't assign requested address") {
                    message = "Wi-Fi 拒绝直接改址，可尝试勾选“重启 Wi-Fi 后修改”。"
                }
                details = result.output.isEmpty ? "命令退出状态：\(result.status)" : result.output
            } else {
                message = "命令已执行，但地址未生效，网卡或驱动可能拒绝了修改。"
                details = "目标地址：\(mac)\n实际地址：\(actual.address)\n\(result.output)"
            }
        }
    }
}

struct MainView: View {
    @StateObject private var model = SwitchModel()
    @State private var showDetails = false

    var body: some View {
        HStack(spacing: 0) {
            editor.frame(minWidth: 470, idealWidth: 510, maxWidth: 560)
            Divider()
            AddressListView(model: model).frame(minWidth: 380, maxWidth: .infinity)
        }
        .frame(minWidth: 910, idealWidth: 990, minHeight: 680, idealHeight: 710)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.refresh(); model.selectionChanged() }
        .onChange(of: model.selectedID) { _ in model.selectionChanged() }
        .onChange(of: model.details) { _ in showDetails = !model.details.isEmpty }
        .alert(model.restoring ? "恢复这张网卡的原始记录地址？" : "修改这张网卡的 MAC 地址？", isPresented: $model.confirmation) {
            Button("取消", role: .cancel) {}
            Button("继续") { model.apply() }
        } message: {
            Text("\(model.selected?.displayName ?? "")\n\(model.proposedAddress)\n\n\(model.selected?.isWiFi == true && model.restartWiFi ? "将关闭并重新打开 Wi-Fi，当前无线连接会中断。" : "可能短暂断网。")系统将请求管理员授权。重新插拔或重启后，地址可能恢复。")
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: "network")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.teal)
                    .frame(width: 46, height: 46)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("MAC Switch").font(.system(size: 23, weight: .semibold))
                    Text(model.demo ? "演示模式" : "网卡地址").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button { model.refresh() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 20, height: 20)
                }
                .help("刷新网卡列表")
                .accessibilityLabel("刷新网卡列表")
                .disabled(model.busy)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("网络接口").font(.headline)
                Picker("网络接口", selection: $model.selectedID) {
                    if model.devices.isEmpty { Text("未发现可用网卡").tag("") }
                    ForEach(model.devices) { device in
                        Text(device.displayName).tag(device.id)
                    }
                }
                .labelsHidden().controlSize(.large)
                .disabled(model.busy || model.devices.isEmpty)
                .accessibilityIdentifier("devicePicker")

                if let device = model.selected {
                    HStack(spacing: 6) {
                        Image(systemName: device.isWiFi ? "wifi" : "cable.connector")
                        Text(device.isWiFi ? "Wi-Fi" : "有线接口")
                        Spacer()
                        Image(systemName: device.enabled ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(device.enabled ? .green : .secondary)
                        Text(device.enabled ? "接口已启用" : "接口未启用")
                    }.font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("未发现可用的物理网卡。").font(.caption).foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow {
                    Text("当前 MAC").foregroundStyle(.secondary)
                    Text(model.selected?.address ?? "—")
                        .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Button {
                        guard let value = model.selected?.address else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("复制当前 MAC")
                    .accessibilityLabel("复制当前 MAC").disabled(model.selected == nil)
                }
                GridRow {
                    Text("原始记录").foregroundStyle(.secondary).help("首次记录到的地址，不一定是出厂地址")
                    Text(model.original ?? "未记录")
                        .font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Color.clear.frame(width: 16, height: 1)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("目标 MAC").font(.headline)
                HStack(spacing: 10) {
                    TextField("02:11:22:33:44:55", text: $model.target)
                        .font(.system(size: 19, design: .monospaced))
                        .textFieldStyle(.roundedBorder).controlSize(.large)
                        .accessibilityLabel("目标 MAC")
                        .accessibilityIdentifier("targetMAC")
                        .disabled(model.busy || model.selected == nil)
                    Button { model.target = MACAddress.random() } label: {
                        Image(systemName: "dice").frame(width: 22, height: 22)
                    }
                    .controlSize(.large).help("随机生成 MAC")
                    .accessibilityLabel("随机生成 MAC")
                    .disabled(model.busy || model.selected == nil)
                }
                Text(!model.target.isEmpty && model.normalized == nil ? "请输入有效的单播 MAC 地址，不能为全零或广播地址。" : " ")
                    .font(.caption).foregroundStyle(.red).frame(minHeight: 16, alignment: .leading)
                if model.selected?.isWiFi == true {
                    Toggle("重启 Wi-Fi 后修改", isOn: $model.restartWiFi)
                        .toggleStyle(.checkbox).disabled(model.busy)
                        .accessibilityIdentifier("restartWiFi")
                }
            }

            HStack {
                Button { model.prepare(restore: true) } label: {
                    Label("恢复原始地址", systemImage: "arrow.uturn.backward")
                }.disabled(!model.canRestore)
                Spacer()
                Button { model.prepare(restore: false) } label: {
                    Label("应用修改", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!model.canApply)
            }

            if !model.message.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(model.message, systemImage: model.busy ? "clock" : (model.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle"))
                        .font(.callout)
                        .foregroundStyle(model.busy ? Color.secondary : (model.succeeded ? Color.green : Color.orange))
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.details.isEmpty {
                        DisclosureGroup("详细信息", isExpanded: $showDetails) {
                            ScrollView {
                                Text(model.details).font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(height: 76)
                        }.font(.caption)
                    }
                }.accessibilityIdentifier("resultStatus")
            }
            Spacer(minLength: 0)
        }
        .padding(28)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@main
struct MACSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        if ProcessInfo.processInfo.arguments.contains("--inspect") {
            if let data = try? JSONEncoder().encode(NetworkInventory.read()) {
                print(String(decoding: data, as: UTF8.self))
            }
            exit(0)
        }
    }

    var body: some Scene {
        Window("MAC Switch", id: "main") { MainView() }
            .defaultSize(width: 990, height: 710)
            .windowResizability(.contentMinSize)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
