#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

private struct SummaryDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct SummaryHome: View {
    @ObservedObject var probe: Probe
    @State private var jobs: [SummaryJob] = []
    @State private var date = Date.now
    @State private var message: String?
    @State private var exportJob: SummaryJob?
    @State private var exportDocument: SummaryDocument?
    @State private var confirmingExport = false
    @State private var exporting = false
    @State private var importing = false

    var body: some View {
        List {
            Section("每天 23:59") {
                Text("系统允许时创建待总结任务。打开 App 时会补做遗漏的日期。")
                Text("使用已授权 ChatGPT 的 Windows 工具分析，完成后导入结果。")
                    .foregroundStyle(.secondary)
            }
            Section("手动总结") {
                DatePicker("日期", selection: $date, in: ...Date.now, displayedComponents: .date)
                Button("准备总结") { create(repeatAnalysis: false) }
                Button("重新总结") { create(repeatAnalysis: true) }
                Button("导入 ChatGPT 结果") { importing = true }
                if let message { Text(message).font(.footnote) }
            }
            Section("历史") {
                if jobs.isEmpty { Text("还没有总结任务").foregroundStyle(.secondary) }
                ForEach(jobs) { job in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(job.input.day).font(.headline)
                        if let text = job.result?.summary, job.result?.status == "completed" {
                            Text(text).textSelection(.enabled)
                        } else {
                            Text(status(job)).foregroundStyle(.secondary).font(.subheadline)
                            Button("导出待分析数据\(job.result == nil ? "" : "并重试")") {
                                exportJob = job
                                confirmingExport = true
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("总结")
        .onAppear { DailyQueue.enqueueDue(); reload() }
        .confirmationDialog("导出当天的情绪计数和可用生理指标平均值？",
            isPresented: $confirmingExport, presenting: exportJob) { job in
                Button("同意并选择保存位置") { export(job) }
                Button("取消", role: .cancel) {}
            } message: { _ in
                Text("导出不含坐标、录音、转写或账号信息。需在 Windows 上主动运行分析。")
            }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json,
            defaultFilename: "moodflow-\(exportJob?.input.day ?? DailyQueue.day(date))-request") { result in
                if case .success = result { message = "已导出。可在 Windows 发起分析。" }
            }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { selected in
            do {
                let url = try selected.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try DailyQueue.importResult(Data(contentsOf: url))
                reload()
                message = "已导入结果"
            } catch { message = "无法导入。请选择与本机待分析任务对应的结果文件。" }
        }
    }

    private func status(_ job: SummaryJob) -> String {
        switch job.result?.reason {
        case "usage_limit": "ChatGPT 额度不足"
        case "authorization": "需要重新授权 ChatGPT"
        case "offline": "分析时网络不可用"
        case "other": "分析未完成"
        default: "等待 ChatGPT 分析"
        }
    }

    private func reload() {
        do { jobs = try DailyQueue.jobs() }
        catch { message = "无法读取本机总结。" }
    }

    private func create(repeatAnalysis: Bool) {
        do {
            message = try DailyQueue.request(date, entries: probe.entries, repeatAnalysis: repeatAnalysis) == nil
                ? "当天还没有心情记录。" : "可在历史里查看或导出这一天的任务。"
            reload()
        } catch { message = "无法保存总结任务。" }
    }

    private func export(_ job: SummaryJob) {
        do { exportDocument = SummaryDocument(data: try JSONEncoder().encode(job.input)); exporting = true }
        catch { message = "无法导出总结任务。" }
    }
}
#endif
