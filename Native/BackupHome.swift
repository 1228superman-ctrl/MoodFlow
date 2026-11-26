#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

private let backupType = UTType(exportedAs: "org.moodflow.journal-backup", conformingTo: .package)

private struct BackupManifest: Codable {
    let version: Int
    let entries: [Entry]
    let audio: [String]

    static func belongsInBackup(_ entry: Entry) -> Bool {
        entry.isMoodEvent || ["情绪反馈", "录音结束", "本地转写"].contains(entry.kind)
    }

    static func read(from folder: URL) throws -> Self {
        let file = folder.appendingPathComponent("journal.json")
        try assertRegular(file)
        let result = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        guard result.version == 1, result.entries.allSatisfy({
            UUID(uuidString: $0.id) != nil && belongsInBackup($0)
        }), Set(result.entries.map(\.id)).count == result.entries.count,
            Set(result.audio).count == result.audio.count else { throw CocoaError(.fileReadCorruptFile) }
        let referenced = Set(result.entries.compactMap(\.audioName))
        for name in result.audio {
            guard referenced.contains(name), Journal.audioURL(name) != nil else { throw CocoaError(.fileReadCorruptFile) }
            try assertRegular(folder.appendingPathComponent(name))
        }
        return result
    }

    private static func assertRegular(_ file: URL) throws {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
    }

    func restore(from folder: URL, into target: URL? = nil) throws -> [Entry] {
        let directory = try target ?? Journal.directory()
        for name in audio {
            let source = folder.appendingPathComponent(name)
            try Self.installFile(directory: directory, name: name) { target in
                try FileManager.default.copyItem(at: source, to: target)
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
            }
        }
        let encoder = JSONEncoder()
        var imported: [Entry] = []
        for entry in entries {
            let inserted = try Self.installFile(directory: directory, name: entry.id + ".json") { target in
                try encoder.encode(entry).write(to: target, options: .completeFileProtectionUntilFirstUserAuthentication)
            }
            if inserted { imported.append(entry) }
        }
        return imported
    }

    @discardableResult
    private static func installFile(directory: URL, name: String, prepare: (URL) throws -> Void) throws -> Bool {
        let manager = FileManager.default
        let target = directory.appendingPathComponent(name)
        guard !manager.fileExists(atPath: target.path) else { return false }
        let temporary = directory.appendingPathComponent("restore-" + UUID().uuidString)
        defer { try? manager.removeItem(at: temporary) }
        try prepare(temporary)
        do { try manager.moveItem(at: temporary, to: target) }
        catch {
            if manager.fileExists(atPath: target.path) { return false }
            throw error
        }
        return true
    }
}

private struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [backupType] }
    let wrapper: FileWrapper

    init(configuration: ReadConfiguration) throws { wrapper = configuration.file }

    init(snapshot: [Entry], audioDirectory: URL? = nil) throws {
        let entries = snapshot.filter(BackupManifest.belongsInBackup)
        var files: [String: FileWrapper] = [:]
        for name in Set(entries.compactMap(\.audioName)) {
            guard let local = Journal.audioURL(name) else { continue }
            let url = audioDirectory?.appendingPathComponent(name) ?? local
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            files[name] = try FileWrapper(url: url, options: [])
        }
        let manifest = BackupManifest(version: 1, entries: entries, audio: files.keys.sorted())
        files["journal.json"] = FileWrapper(regularFileWithContents: try JSONEncoder().encode(manifest))
        wrapper = FileWrapper(directoryWithFileWrappers: files)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { wrapper }
}

struct BackupHome: View {
    @ObservedObject var probe: Probe
    @State private var document: BackupDocument?
    @State private var selected: URL?
    @State private var preview: BackupManifest?
    @State private var exporting = false
    @State private var importing = false
    @State private var confirming = false
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        Form {
            Button("导出备份") {
                busy = true
                Task {
                    await probe.loadHistoryIfNeeded()
                    let entries = probe.entries
                    do {
                        document = try await Task.detached(priority: .userInitiated) {
                            try BackupDocument(snapshot: entries)
                        }.value
                        exporting = true
                    } catch { message = "准备备份失败，请重试。" }
                    busy = false
                }
            }
            Button("从备份恢复") { importing = true }
            Text("备份含心情、关联健康信息、录音和转写。请选择你信任的保存位置。").font(.footnote)
            if busy { ProgressView("正在处理…") }
            if let message { Text(message).font(.footnote) }
        }
        .disabled(busy)
        .navigationTitle("备份与恢复")
        .fileExporter(isPresented: $exporting, document: document, contentType: backupType, defaultFilename: "心绪备份") { result in
            if case .success = result { message = "已导出备份。" }
            else { message = "导出备份失败。" }
            document = nil
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [backupType]) { result in
            guard case .success(let url) = result else { return }
            busy = true
            Task {
                do {
                    let manifest = try await Task.detached(priority: .userInitiated) {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        return try BackupManifest.read(from: url)
                    }.value
                    selected = url
                    preview = manifest
                    confirming = true
                } catch { message = "无法读取该备份。" }
                busy = false
            }
        }
        .confirmationDialog("恢复备份", isPresented: $confirming, titleVisibility: .visible) {
            Button("合并到当前记录") { restoreSelection() }
            Button("取消", role: .cancel) {}
        } message: {
            if let preview {
                Text("备份包含 \(preview.entries.filter(\.isMoodEvent).count) 条心情或波动、\(preview.audio.count) 段录音。已有文件会保留。")
            }
        }
    }

    private func restoreSelection() {
        guard let selected else { return }
        busy = true
        Task {
            do {
                let metadata = try await Task.detached(priority: .userInitiated) {
                    let access = selected.startAccessingSecurityScopedResource()
                    defer { if access { selected.stopAccessingSecurityScopedResource() } }
                    return try BackupManifest.read(from: selected).restore(from: selected)
                }.value
                probe.didRestoreBackup(metadata)
                message = "已补齐缺失文件，新增 \(metadata.filter(\.isMoodEvent).count) 条心情或波动。"
            } catch {
                // A restore can be retried; files installed before a failure remain intact.
                await probe.refreshRestoredHistory()
                message = "恢复未完成，已保留成功写入的记录。可以重试同一备份。"
            }
            busy = false
        }
    }

    #if targetEnvironment(simulator) && MOODFLOW_SIM
    static func checkSyntheticRoundTrip() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let local = base.appendingPathComponent("source")
        let restored = base.appendingPathComponent("restored")
        try manager.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        try manager.createDirectory(at: restored, withIntermediateDirectories: false)
        let folder = base.appendingPathComponent("fixture.moodflowbackup")
        let name = UUID().uuidString + ".m4a"
        let clip = Entry(kind: "录音结束", detail: "模拟备份", recording: name)
        let mood = Entry(kind: "手动心情", detail: "模拟备份")
        let original = Data([23, 42, 14])
        try original.write(to: local.appendingPathComponent(name))
        let document = try BackupDocument(snapshot: [clip, mood], audioDirectory: local)
        try document.wrapper.write(to: folder, options: .atomic, originalContentsURL: nil)
        let manifest = try BackupManifest.read(from: folder)
        guard manifest.entries.count == 2, manifest.audio == [name],
              try manifest.restore(from: folder, into: restored).count == 2,
              try Data(contentsOf: restored.appendingPathComponent(name)) == original,
              try manifest.restore(from: folder, into: restored).isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
    #endif
}
#endif
