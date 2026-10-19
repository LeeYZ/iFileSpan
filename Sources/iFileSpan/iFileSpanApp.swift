import SwiftUI
import DeviceCore
import UniformTypeIdentifiers

@main
struct iFileSpanApp: App {
    @NSApplicationDelegateAdaptor(ApplicationLifecycle.self) private var lifecycle
    @State private var model = AppModel()
    @State private var didStart = false
    var body: some Scene {
        Window("iFileSpan", id: ApplicationLifecycle.mainWindowID) {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 620)
                .modifier(MainWindowReopenRegistration(lifecycle: lifecycle))
                .task {
                    guard !didStart else { return }
                    didStart = true
                    model.detect(refreshPermissions: false)
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            FileBrowserCommands()
            CommandGroup(replacing: .newItem) {
                Button("显示主窗口") { lifecycle.restoreMainWindow() }
                    .keyboardShortcut("0", modifiers: .command)
                Button("安装 IPA…") { model.installIPA() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(!model.canInstallIPA)
            }
            CommandGroup(after: .toolbar) {
                Button("重新检测设备") { model.detect() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.busy)
                Button("刷新目录") { model.navigate(model.directory) }.keyboardShortcut("r").disabled(model.root == nil || model.busy)
                Button("打开本地备份") { model.revealBackups() }
            }
            CommandGroup(replacing: .help) { Button("使用说明与访问范围") { model.helpSheet = true } }
        }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 240, ideal: 275, max: 350)
        } detail: {
            VStack(spacing: 0) {
                fileHeader
                Divider()
                if model.root != nil { fileTable }
                else { emptyState }
                Divider()
                statusBar
            }
        }
        .toolbar { toolbar }
        .alert("操作提示", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .sheet(isPresented: $model.helpSheet) { help }
        .sheet(isPresented: $model.newFolderSheet) {
            VStack(alignment: .leading, spacing: 16) {
                Text("新建文件夹").font(.headline)
                TextField("文件夹名称", text: $model.folderName).onSubmit { model.createFolder() }
                HStack { Spacer(); Button("取消") { model.newFolderSheet = false }; Button("创建") { model.createFolder() }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 370)
        }
        .sheet(isPresented: $model.manualSheet) {
            VStack(alignment: .leading, spacing: 16) {
                Text("按 App 标识符打开").font(.headline)
                Text("输入 Bundle ID，例如 org.videolan.vlc-ios。访问仍需设备授权。")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("com.example.app", text: $model.manualBundle)
                HStack {
                    Spacer(); Button("取消") { model.manualSheet = false }
                    Button("打开") {
                        let id = model.manualBundle.trimmingCharacters(in: .whitespacesAndNewlines)
                        model.manualSheet = false; model.open(bundle: id, title: id)
                    }.keyboardShortcut(.defaultAction).disabled(model.manualBundle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 440)
        }
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Label("iFileSpan", systemImage: "iphone.and.ipad").font(.title3.bold())
                Picker("设备", selection: Binding(get: { model.deviceID }, set: { model.pickDevice($0) })) {
                    if model.devices.isEmpty { Text("未连接设备").tag("") }
                    ForEach(model.devices) { device in Text(device.name).tag(device.id) }
                }.labelsHidden()
                if let device = model.currentDevice {
                    Text("\(device.model) · iOS / iPadOS \(device.version)").font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button { model.openMedia() } label: { Label("共享媒体目录", systemImage: "photo.on.rectangle") }
                    .disabled(model.deviceID.isEmpty)
                Button { model.installIPA() } label: { Label("安装 IPA…", systemImage: "square.and.arrow.down") }
                    .disabled(!model.canInstallIPA)
                    .help("选择有效签名的 IPA，安装到当前设备 ⇧⌘I")
                TextField("搜索 App 名称或标识符", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                Toggle("隐藏无权限的 App", isOn: $model.hideRestrictedApps).font(.caption)
                    .help("只读检查所有 App 的容器和 Documents；两者均明确被拒绝的 App 会隐藏。关闭可查看全部，检查期间暂不显示待检查项目。")
                Toggle("只显示开启文件共享的 App", isOn: $model.sharingOnly).font(.caption)
                if model.checkingAppAccess {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在检查 App 权限 · 剩余 \(model.pendingAppCount)")
                    }.font(.caption).foregroundStyle(.secondary)
                }
                if model.hideRestrictedApps && model.restrictedAppCount > 0 {
                    Text("已隐藏 \(model.restrictedAppCount) 个无权限的 App")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.unknownAppCount > 0 {
                    Text("部分 App 权限未确认，已保留显示。解锁并重新检测可重试。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    HStack { Text("应用程序").font(.caption.bold()).foregroundStyle(.secondary); Spacer(); Text("\(model.visibleApps.count) / \(model.apps.count)").font(.caption).foregroundStyle(.secondary) }.padding(.horizontal, 8)
                    ForEach(model.visibleApps) { app in
                        Button { model.openApp(app) } label: {
                            HStack(spacing: 10) {
                                appIcon(app)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(app.name).font(.body.weight(.medium)).lineLimit(1)
                                    Text(app.id).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: model.appAvailability[app.id] == .restricted ? "lock.fill" :
                                    (app.fileSharing || model.appAvailability[app.id] == .available ? "folder.badge.checkmark" : "app.badge"))
                                    .foregroundStyle(.secondary)
                                    .help(model.appAvailability[app.id] == .restricted ? "设备未开放此 App 的容器和 Documents" :
                                        (app.fileSharing ? "已开启文件共享" : "访问范围由设备实际授权决定"))
                            }.padding(9).contentShape(Rectangle())
                                .background(model.activeBundle == app.id ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                            .task(id: model.sidebarGeneration) { await model.loadIcon(app) }
                    }
                    if model.visibleApps.isEmpty {
                        Text(model.apps.isEmpty ? "连接设备后显示 App" : (model.checkingAppAccess ? "正在检查权限，可访问的 App 会陆续显示。" : "没有匹配的 App，可清除搜索或调整上方筛选。"))
                            .font(.callout).foregroundStyle(.secondary).padding()
                    }
                }.padding(8)
            }
            Divider()
            Button { model.manualSheet = true } label: { Label("输入 App 标识符…", systemImage: "plus.magnifyingglass").frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.plain).padding(16).disabled(model.deviceID.isEmpty)
        }.disabled(model.busy)
    }
    @ViewBuilder private func appIcon(_ app: DeviceApp) -> some View {
        Group {
            if let image = model.appIcons[app.id] {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "app.fill").resizable().scaledToFit()
                    .foregroundStyle(.secondary).padding(5)
            }
        }.frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)
    }
    private var fileHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.activeTitle).font(.title2.bold())
                    Text(model.connectionInfo?.title ?? "通过 USB 管理 iPhone 与 iPad 的可访问文件")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("访问范围", selection: Binding(get: { model.accessMode }, set: { model.changeMode($0) })) {
                    ForEach(AppAccessMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                }.frame(width: 310).disabled(model.busy)
            }
            HStack(spacing: 8) {
                Button { model.navigate(RemotePath.parent(model.directory)) } label: { Image(systemName: "arrow.up") }
                    .help("上一级目录").disabled(model.busy || model.root == nil || model.directory == model.root)
                Button { if let root = model.root { model.navigate(root) } } label: { Image(systemName: "house") }
                    .help("返回当前目录根部").disabled(model.busy || model.root == nil)
                Text(model.root == nil ? "等待选择目录" : model.directory)
                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                Spacer()
                if let selected = model.selected {
                    Text(selected.kind == .directory ? "文件夹" : ByteCountFormatter.string(fromByteCount: Int64(clamping: selected.size), countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.selectedPaths.count > 1 {
                    Text("已选 \(model.selectedPaths.count) 个项目").font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.connectionInfo?.scope == .container {
                HStack {
                    Text("进入目录：").font(.caption).foregroundStyle(.secondary)
                    ForEach(["Documents", "Library", "tmp"], id: \.self) { folder in
                        Button(folder) { model.navigate("/" + folder) }.disabled(model.busy)
                    }
                }
            }
            if let limitation = model.connectionInfo?.limitation {
                Label { Text(limitation).font(.callout).textSelection(.enabled) } icon: {
                    Image(systemName: "lock.shield").foregroundStyle(.orange)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }.padding(20)
    }
    private var fileTable: some View {
        Table(model.entries, selection: $model.selectedPaths) {
            TableColumn("名称") { entry in
                HStack {
                    Image(systemName: icon(entry)).foregroundStyle(entry.kind == .directory ? Color.accentColor : .secondary)
                    Text(entry.name).lineLimit(1)
                }.help(entry.accessError ?? entry.name).contentShape(Rectangle()).onTapGesture(count: 2) {
                    if entry.kind == .directory { model.navigate(entry.path) }
                }
            }.width(min: 200, ideal: 360)
            TableColumn("大小") { entry in
                Text(entry.kind == .file ? ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file) : "—")
                    .foregroundStyle(.secondary).monospacedDigit()
            }.width(100)
            TableColumn("修改时间") { entry in
                Text(entry.modified?.formatted(date: .numeric, time: .shortened) ?? "—").foregroundStyle(.secondary)
            }.width(min: 150, ideal: 170)
            TableColumn("类型") { entry in Text(kind(entry)).foregroundStyle(.secondary) }.width(90)
        }
        .focusedValue(\.fileBrowserModel, model)
        .onCommand(#selector(NSText.selectAll(_:)), perform: model.busy ? nil : { model.selectAllFiles() })
        .onCommand(#selector(NSText.copy(_:)), perform: model.canCopy ? { model.copySelection() } : nil)
        .onPasteCommand(of: [.fileURL], validator: { providers in model.busy ? nil : providers }) { _ in
            model.pasteFromClipboard()
        }
        .onExitCommand { model.selectedPaths = [] }
        .disabled(model.busy)
        .contextMenu(forSelectionType: String.self) { paths in
            let items = model.entries.filter { paths.contains($0.path) }
            let item = items.count == 1 ? items.first : nil
            if let item, item.kind == .directory {
                Button("打开文件夹") { model.navigate(item.path) }.disabled(model.busy)
            }
            Button("下载到 Mac…") {
                model.selectedPaths = paths; model.download()
            }.disabled(!items.contains { $0.kind == .file || $0.kind == .directory } || model.busy)
            Button("复制文件") { model.selectedPaths = paths; model.copySelection() }
                .disabled(!items.contains { $0.kind == .file || $0.kind == .directory } || model.busy)
            Button("粘贴到当前目录") { model.pasteFromClipboard() }.disabled(model.busy || model.root == nil)
            Button("替换文件…") {
                if let item { model.selectedPath = item.path; model.upload(replacing: true) }
            }.disabled(item?.kind != .file || model.busy)
            Divider()
            Button("删除文件…", role: .destructive) {
                model.selectedPaths = paths; model.deleteFile()
            }.disabled(items.isEmpty || !items.allSatisfy { $0.kind == .file } || model.busy)
        }
        .overlay { if model.entries.isEmpty && !model.busy { ContentUnavailableView("文件夹为空", systemImage: "folder", description: Text("可上传文件或新建文件夹。")) } }
    }
    private var canDownload: Bool { !model.transferableSelection.isEmpty }
    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.badge.icloud").font(.system(size: 60, weight: .light)).foregroundStyle(Color.accentColor)
            Text(model.dependencyMissing ? "设备连接组件加载失败" : "从设备中选择一个 App").font(.title2.bold())
            Text(model.dependencyMissing ? "本程序已内置连接组件。请重新解压完整安装包后再试。" : "默认显示设备返回的全部 App，并优先请求容器根目录。\niOS 决定是否允许读取 Library、tmp 等私有目录。")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("重新检测") { model.detect() }.buttonStyle(.borderedProminent).disabled(model.busy)
            Button("查看使用说明与访问范围") { model.helpSheet = true }.buttonStyle(.link)
            Text("普通未越狱设备无法任意访问所有 App 的私有沙盒。")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 14)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let value = model.progress {
                if value.total > 0 { ProgressView(value: Double(min(value.completed, value.total)), total: Double(value.total)) }
                else { ProgressView().controlSize(.small) }
                HStack {
                    Text(value.message).lineLimit(1)
                    Spacer()
                    if value.total > 0 {
                        if value.unit == .percent { Text("\(min(value.completed, 100))%").monospacedDigit() }
                        else { Text("\(ByteCountFormatter.string(fromByteCount: Int64(clamping: value.completed), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(clamping: value.total), countStyle: .file))").monospacedDigit() }
                    }
                    if value.cancellable { Button("取消") { model.cancellation.cancel() } }
                }
            } else {
                HStack {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.status).lineLimit(2).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            }
        }.font(.caption).foregroundStyle(.secondary).padding(12).frame(minHeight: 44)
    }
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { model.detect() } label: { Label("重新检测", systemImage: "cable.connector") }.disabled(model.busy)
            Button { model.installIPA() } label: { Label("安装 IPA", systemImage: "square.and.arrow.down") }.disabled(!model.canInstallIPA)
            Button { model.navigate(model.directory) } label: { Label("刷新", systemImage: "arrow.clockwise") }.disabled(model.root == nil || model.busy)
            Divider()
            Button { model.download() } label: { Label("下载", systemImage: "arrow.down.to.line") }.disabled(!canDownload || model.busy)
            Button { model.copySelection() } label: { Label("复制", systemImage: "doc.on.doc") }.disabled(!model.canCopy).help("复制文件 ⌘C")
            Button { model.pasteFromClipboard() } label: { Label("粘贴", systemImage: "clipboard") }.disabled(model.root == nil || model.busy).help("粘贴文件 ⌘V")
            Button { model.upload(replacing: false) } label: { Label("上传", systemImage: "arrow.up.to.line") }.disabled(model.root == nil || model.busy)
            Button { model.upload(replacing: true) } label: { Label("替换", systemImage: "arrow.triangle.2.circlepath") }.disabled(model.selected?.kind != .file || model.busy)
            Button(role: .destructive) { model.deleteFile() } label: { Label("删除文件", systemImage: "trash") }.disabled(!model.canDelete)
            Button { model.newFolderSheet = true } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }.disabled(model.root == nil || model.busy)
            Button { model.revealBackups() } label: { Label("备份", systemImage: "clock.arrow.circlepath") }
            Button { model.helpSheet = true } label: { Label("帮助", systemImage: "questionmark.circle") }
        }
    }
    private var help: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("使用说明与访问范围").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("1. 程序已内置设备连接组件，无需安装 Homebrew。\n2. 使用 USB 连接 iPhone / iPad，解锁并选择“信任此电脑”。\n3. 点“重新检测”，选择设备和 App。双击文件夹进入。\n4. 选中文件后点“下载”或“替换”；“上传”用于添加新文件。")
                        .lineSpacing(6)
                    Divider()
                    Text("自动：优先请求 App 容器根目录；访问失败后尝试 Documents，并在主界面保留限制原因。\n容器根目录：从 / 浏览设备开放的目录，可尝试 Documents、Library、tmp；设备拒绝时直接显示错误。\n仅 Documents：只请求文件共享目录。\n共享媒体：只显示设备开放的媒体文件区，不能代替照片图库管理。")
                        .lineSpacing(5)
                    Text("应用列表默认不筛选文件共享状态。显示 App 不代表能读取其私有沙盒。普通未越狱设备通常无法直接读取第三方 App 的 Library、tmp。iExplorer 的备份浏览读取的是备份中的副本；tmp 通常不进入备份。本版本未集成备份解析或 Xcode 调试服务。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("替换或删除前请关闭目标 App。替换会保存本地备份；删除在确认后直接执行，不创建备份。删除需选中普通文件，可从工具栏或右键菜单发起，删除后无法通过本程序恢复。提交时请保持设备连接；断线后请刷新确认实际结果。")
                        .font(.callout)
                    Text("文件列表快捷键：⌘A 全选、⌘C 复制到文件剪贴板、⌘V 上传粘贴、⌘⌫ 删除、⇧⌘N 新建文件夹、⌘↑ 上一级、⌘↓ 打开文件夹、⌘R 刷新。支持 Command / Shift 多选；文字输入框使用正常的文字编辑快捷键。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("安装 IPA：选择设备后点“安装 IPA”，或按 ⇧⌘I，检查应用名称、版本与设备后确认。IPA 必须具备设备认可的签名与描述文件；本程序不会重签名或绕过系统限制。上传可取消，提交安装后请等待设备结果。同标识符的已有 App 可能被更新，请先自行备份其重要数据。")
                        .font(.callout)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("打开备份目录") { model.revealBackups() }
                Spacer()
                Button("完成") { model.helpSheet = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 650, height: 650)
    }
    private func icon(_ e: RemoteEntry) -> String { e.accessError != nil ? "lock.fill" : e.kind == .directory ? "folder.fill" : e.kind == .symbolicLink ? "link" : "doc" }
    private func kind(_ e: RemoteEntry) -> String {
        if e.accessError != nil { return "权限受限" }
        return switch e.kind { case .file: "文件"; case .directory: "文件夹"; case .symbolicLink: "符号链接"; case .other: "特殊文件" }
    }
}
