import SwiftUI

private struct FileBrowserModelKey: FocusedValueKey { typealias Value = AppModel }
extension FocusedValues {
    var fileBrowserModel: AppModel? {
        get { self[FileBrowserModelKey.self] }
        set { self[FileBrowserModelKey.self] = newValue }
    }
}

struct FileBrowserCommands: Commands {
    @FocusedValue(\.fileBrowserModel) private var model
    var body: some Commands {
        CommandMenu("文件操作") {
            Button("新建文件夹…") { model?.newFolderSheet = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model == nil || model?.busy == true || model?.root == nil)
            Button("打开选中的文件夹") { model?.openSelectedFolder() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(model?.selected?.kind != .directory || model?.busy == true)
            Button("返回上一级") { model?.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(model == nil || model?.busy == true || model?.directory == model?.root)
            Divider()
            Button("删除选中文件…", role: .destructive) { model?.deleteFile() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model?.canDelete != true)
        }
    }
}
