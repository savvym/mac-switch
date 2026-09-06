import SwiftUI
import AppKit

struct AddressListView: View {
    @ObservedObject var model: SwitchModel
    @State private var selection: String?
    @State private var search = ""
    @State private var draft: AddressEditorDraft?
    @State private var deleting = false

    private var entry: SavedAddress? { selection.flatMap { model.addressList?.entries[$0] } }
    private var visibleEntries: [SavedAddress] {
        let entries = model.addressList?.sortedEntries ?? []
        guard !search.isEmpty else { return entries }
        return entries.filter { $0.address.localizedCaseInsensitiveContains(search) || $0.note.localizedCaseInsensitiveContains(search) }
    }
    private var canDelete: Bool {
        guard let entry else { return false }
        return !model.busy && entry.address != model.original && entry.address != model.selected?.address
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("地址列表").font(.title3.weight(.semibold))
                    Text(model.selected?.displayName ?? "未选择设备")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button {
                    draft = .init(existingAddress: nil, address: model.normalized ?? "", note: "")
                } label: { Image(systemName: "plus") }
                .help("添加 MAC 地址").accessibilityLabel("添加 MAC 地址")
                .disabled(model.selected == nil || model.busy)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索地址或备注", text: $search).textFieldStyle(.plain)
                    .accessibilityLabel("搜索地址或备注")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).help("清除搜索").accessibilityLabel("清除搜索")
                }
            }.padding(8).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

            if visibleEntries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "list.bullet.rectangle").font(.title).foregroundStyle(.secondary)
                    Text(search.isEmpty ? "暂无地址" : "没有匹配的地址").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(visibleEntries) { item in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(item.address).font(.system(size: 14, weight: .medium, design: .monospaced))
                                HStack(spacing: 9) {
                                    if item.address == model.original {
                                        Label("原始", systemImage: "pin.fill").foregroundStyle(.teal)
                                            .help("该设备首次记录的地址，不一定是出厂地址")
                                    }
                                    if item.address == model.selected?.address {
                                        Text("当前").foregroundStyle(.green)
                                    }
                                    if item.manuallyAdded { Text("手动").foregroundStyle(.secondary) }
                                    if item.lastSeenAt != nil && item.address != model.original && item.address != model.selected?.address {
                                        Text("历史").foregroundStyle(.secondary)
                                    }
                                }.font(.caption)
                                if !item.note.isEmpty {
                                    Text(item.note).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(2).help(item.note)
                                }
                            }
                            Spacer(minLength: 0)
                            Button { model.prepareAddress(item.address) } label: {
                                Image(systemName: "arrow.left.arrow.right").frame(width: 24, height: 26)
                            }
                            .buttonStyle(.borderless)
                            .help("切换到 \(item.address)")
                            .accessibilityLabel("切换到 \(item.address)")
                            .disabled(model.busy || item.address == model.selected?.address)
                        }
                        .padding(.vertical, 7).tag(item.address)
                        .accessibilityElement(children: .contain)
                    }
                }
                .listStyle(.inset).scrollContentBackground(.hidden)
                .accessibilityIdentifier("addressList")
            }

            if !model.libraryError.isEmpty {
                Label(model.libraryError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }

            Divider()
            HStack(spacing: 16) {
                Text("\(model.addressList?.entries.count ?? 0) 个地址").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    guard let entry else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.address, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .help("复制所选地址").accessibilityLabel("复制所选地址").disabled(entry == nil)
                Button {
                    guard let entry else { return }
                    draft = .init(existingAddress: entry.address, address: entry.address, note: entry.note)
                } label: { Image(systemName: "pencil") }
                .help("编辑备注").accessibilityLabel("编辑备注").disabled(entry == nil || model.busy)
                Button { deleting = true } label: { Image(systemName: "trash") }
                    .help("删除所选地址（原始和当前地址不可删除）")
                    .accessibilityLabel("删除所选地址").disabled(!canDelete)
            }.buttonStyle(.borderless)
        }
        .padding(24)
        .onChange(of: model.selectedID) { _ in selection = nil; search = "" }
        .sheet(item: $draft) { draft in
            AddressEditorView(model: model, draft: draft) { selection = $0 }
        }
        .alert("从该设备列表中删除地址？", isPresented: $deleting) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                if let selection { model.deleteAddress(selection) }
                selection = nil
            }
        } message: { Text("\(selection ?? "")\n不会修改网卡的当前 MAC 地址。") }
    }
}

private struct AddressEditorDraft: Identifiable {
    let id = UUID()
    let existingAddress: String?
    let address: String
    let note: String
}

private struct AddressEditorView: View {
    @ObservedObject var model: SwitchModel
    let draft: AddressEditorDraft
    let onSave: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var formAddress: String
    @State private var formNote: String

    init(model: SwitchModel, draft: AddressEditorDraft, onSave: @escaping (String?) -> Void) {
        self.model = model
        self.draft = draft
        self.onSave = onSave
        _formAddress = State(initialValue: draft.address)
        _formNote = State(initialValue: draft.note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(draft.existingAddress == nil ? "添加 MAC 地址" : "编辑备注").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Text("MAC 地址").font(.subheadline)
                TextField("02:11:22:33:44:55", text: $formAddress)
                    .font(.system(.body, design: .monospaced)).textFieldStyle(.roundedBorder)
                    .disabled(draft.existingAddress != nil).accessibilityLabel("保存的 MAC 地址")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("备注").font(.subheadline)
                TextField("备注（可选）", text: $formNote).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("地址备注")
                    .onChange(of: formNote) { value in if value.count > 80 { formNote = String(value.prefix(80)) } }
            }
            if !formAddress.isEmpty && MACAddress.normalize(formAddress) == nil {
                Text("请输入有效的单播 MAC 地址。").font(.caption).foregroundStyle(.red)
            }
            if !model.libraryError.isEmpty {
                Text(model.libraryError).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    let saved = draft.existingAddress.map { model.renameAddress($0, note: formNote) }
                        ?? model.addAddress(formAddress, note: formNote)
                    if saved { onSave(MACAddress.normalize(formAddress)); dismiss() }
                }
                .keyboardShortcut(.defaultAction).disabled(MACAddress.normalize(formAddress) == nil)
            }
        }.padding(24).frame(width: 380)
    }
}
