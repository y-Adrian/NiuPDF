import AppKit
import MetricKit
import OSLog
import PaperplaneCore
import PDFKit
import SwiftUI

/// Help ▸ Report a Bug: the user describes the problem, sees the whole report
/// (Mac, app and document details, a crash report if there was one, and the
/// app's log of this session), and sends it by email or as an issue, or
/// copies or saves it. Nothing leaves the Mac until the user sends it.
///
/// Where reports go is set in Info.plist: `PaperplaneSupportEmail` (an
/// address) and `PaperplaneIssuesURL` (an issues page, such as
/// https://github.com/owner/repo/issues). Either may be empty.
enum BugReportDestination {
    static var email: String? { value("PaperplaneSupportEmail") }
    static var issues: URL? { value("PaperplaneIssuesURL").flatMap(URL.init(string:)) }

    private static func value(_ key: String) -> String? {
        let text = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}

/// Whether the last run ended without quitting, as after a crash or a forced
/// quit: a flag set at launch and cleared when the app quits.
enum SessionGuard {
    private static let runningKey = "sessionIsRunning"
    static let suppressionKey = "doesNotAskAboutUnexpectedQuits"
    /// Fixed at launch, for the report.
    private(set) static var lastSessionEndedUnexpectedly = false
    private static var offers = false

    static func start() {
        let defaults = UserDefaults.standard
        lastSessionEndedUnexpectedly = defaults.bool(forKey: runningKey)
        offers = lastSessionEndedUnexpectedly
        defaults.set(true, forKey: runningKey)
    }

    /// Also called before "Restart Now" starts the new instance.
    static func end() {
        UserDefaults.standard.set(false, forKey: runningKey)
    }

    /// After launch: offers to report the unexpected end of the last session,
    /// as a sheet on the first reader window once it is on screen.
    @MainActor
    static func offerReportIfNeeded(attempt: Int = 0) {
        guard offers, !UserDefaults.standard.bool(forKey: suppressionKey) else { return }
        guard let window = AppModel.shared.openLibraries.compactMap(\.window).first(where: \.isVisible),
              window.attachedSheet == nil else {
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { offerReportIfNeeded(attempt: attempt + 1) }
            }
            return
        }
        offers = false
        Logger.problems.notice("The last session ended without quitting")
        let alert = NSAlert()
        alert.messageText = L("NiuPDF quit unexpectedly the last time it was used.")
        alert.informativeText = L("If something went wrong, you can report it. You see the whole report before anything is sent.")
        alert.addButton(withTitle: L("Report a Bug…"))
        alert.addButton(withTitle: L("Not Now"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L("Don’t ask again")
        alert.beginSheetModal(for: window) { answer in
            if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: suppressionKey) }
            if answer == .alertFirstButtonReturn { BugReportModel.shared.open(from: nil) }
        }
    }
}

extension Logger {
    /// Problems the user was told about, and other things worth a bug report.
    static let problems = Logger(subsystem: "app.paperplane.reader", category: "problem")
}

/// Crash reports that macOS hands the app through MetricKit, usually at the
/// next launch, kept as text in the app's support folder (newest five).
final class CrashReports: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReports()
    private static let limit = 5

    static var folder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Paperplane/Crash Reports", isDirectory: true)
    }

    func start() {
        MXMetricManager.shared.add(self)
        // Payloads from before this launch that were not handed over yet.
        didReceive(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard let folder = Self.folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for payload in payloads {
            for (index, crash) in (payload.crashDiagnostics ?? []).enumerated() {
                // Named by time, so a payload handed over twice is kept once.
                let name = "\(Int(payload.timeStampEnd.timeIntervalSince1970))-\(index).txt"
                try? Self.describe(crash, at: payload.timeStampEnd).write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        }
        let stored = Self.stored()
        for old in stored.dropFirst(Self.limit) { try? FileManager.default.removeItem(at: old.url) }
    }

    private static func describe(_ crash: MXCrashDiagnostic, at date: Date) -> String {
        var lines = ["Date: \(ISO8601DateFormatter().string(from: date))",
                     "App build: \(crash.metaData.applicationBuildVersion)",
                     "OS: \(crash.metaData.osVersion)"]
        if let type = crash.exceptionType { lines.append("Exception type: \(type)") }
        if let code = crash.exceptionCode { lines.append("Exception code: \(code)") }
        if let signal = crash.signal { lines.append("Signal: \(signal)") }
        if let reason = crash.terminationReason { lines.append("Termination reason: \(reason)") }
        if let region = crash.virtualMemoryRegionInfo { lines.append("Memory region: \(region)") }
        let stack = String(decoding: crash.callStackTree.jsonRepresentation(), as: UTF8.self)
        lines.append("Call stack tree (JSON):\n\(stack)")
        return lines.joined(separator: "\n")
    }

    /// Stored reports, newest first.
    static func stored() -> [(url: URL, date: Date)] {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.compactMap { name -> (URL, Date)? in
            guard name.hasSuffix(".txt"), let seconds = Double(name.prefix { $0.isNumber }) else { return nil }
            return (folder.appendingPathComponent(name), Date(timeIntervalSince1970: seconds))
        }
        .sorted { $0.1 > $1.1 }
    }

    /// The newest report from the last two weeks.
    static func latest() -> (date: Date, text: String)? {
        guard let newest = stored().first, newest.date > Date().addingTimeInterval(-14 * 24 * 3600),
              let text = try? String(contentsOf: newest.url, encoding: .utf8) else { return nil }
        return (newest.date, text)
    }
}

@MainActor
final class BugReportModel: ObservableObject {
    static let shared = BugReportModel()

    @Published var summary = ""
    @Published var steps = ""
    @Published var includesDocument = true
    @Published var includesCrash = true
    @Published var includesLog = true
    @Published private(set) var systemSection = BugReport.Section(title: "System", lines: [])
    @Published private(set) var documentSection: BugReport.Section?
    @Published private(set) var crash: (date: Date, text: String)?
    @Published private(set) var log: [String] = []
    @Published var status: String?

    /// Opens the window; set by the first reader window from SwiftUI's environment.
    var openWindowAction: (() -> Void)?

    /// Gathers the details, of `library`'s document or the frontmost one, and
    /// shows the window.
    func open(from library: ReaderLibrary?) {
        status = nil
        systemSection = Self.systemDetails()
        documentSection = (library ?? AppModel.shared.activeLibrary).flatMap(Self.documentDetails)
        crash = CrashReports.latest()
        log = Self.sessionLog()
        openWindowAction?()
    }

    var report: BugReport {
        var sections = [systemSection]
        if includesDocument, let documentSection { sections.append(documentSection) }
        return BugReport(summary: summary, steps: steps, sections: sections,
                         crash: includesCrash ? crash?.text : nil, log: includesLog ? log : [])
    }

    var canSend: Bool { !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func copy() {
        copyToClipboard(report.text)
        status = L("The report is on the clipboard.")
    }

    func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = L("NiuPDF Bug Report %@.txt", Self.day.string(from: Date()))
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report.text.write(to: url, atomically: true, encoding: .utf8)
            status = L("Saved “%@”.", url.lastPathComponent)
        } catch {
            status = error.localizedDescription
        }
    }

    func sendByEmail() {
        guard let address = BugReportDestination.email else { return }
        send(report.mailURL(to: address, subjectPrefix: "[\(L("NiuPDF"))] "))
    }

    func openIssuePage() {
        guard let issues = BugReportDestination.issues else { return }
        send(report.issueURL(issues: issues))
    }

    private func send(_ link: (url: URL, isShortened: Bool)?) {
        guard let link else {
            status = L("The description is too long to send this way. Copy or save the report instead.")
            return
        }
        if link.isShortened {
            copyToClipboard(report.text)
            status = L("The report was too long for a link, so it was shortened. The whole report is on the clipboard; paste it in.")
        } else {
            status = nil
        }
        if !NSWorkspace.shared.open(link.url) {
            status = L("No app could open the link. Copy or save the report instead.")
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: Details

    private static func systemDetails() -> BugReport.Section {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "Apple silicon"
        #else
        let architecture = "Intel"
        #endif
        let memory = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        let autosaves = UserDefaults.standard.object(forKey: ReaderLibrary.autosaveKey) as? Bool ?? true
        return BugReport.Section(title: "System", lines: [
            (L("NiuPDF"), "\(version) (\(build))"),
            ("macOS", "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(sysctl("kern.osversion") ?? "unknown"))"),
            ("Mac", "\(sysctl("hw.model") ?? "unknown"), \(architecture), \(String(format: "%.0f", memory)) GB"),
            ("Languages", Locale.preferredLanguages.prefix(3).joined(separator: ", ") + "; app: \(AppLanguage.saved.rawValue)"),
            ("Sandboxed", ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil ? "no" : "yes"),
            ("Autosave", autosaves ? "on" : "off"),
            ("Open windows", "\(AppModel.shared.openLibraries.count)"),
            ("Last session ended unexpectedly", SessionGuard.lastSessionEndedUnexpectedly ? "yes" : "no")
        ])
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }

    /// The document's shape, not its name, title, author or text.
    private static func documentDetails(of library: ReaderLibrary) -> BugReport.Section? {
        guard let document = library.document else { return nil }
        var annotations = 0, fields = 0
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] {
                if annotation.type == "Widget" { fields += 1 } else { annotations += 1 }
            }
        }
        var lines: [(name: String, value: String)] = [
            ("Pages", "\(document.pageCount)"),
            ("PDF version", "\(document.majorVersion).\(document.minorVersion)")
        ]
        if let url = library.fileURL, let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            lines.append(("File size", ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))
        }
        var restrictions = [String]()
        if !document.allowsPrinting { restrictions.append("printing") }
        if !document.allowsCopying { restrictions.append("copying") }
        if !document.allowsCommenting { restrictions.append("commenting") }
        if !document.allowsDocumentChanges { restrictions.append("changes") }
        lines.append(("Encrypted", document.isEncrypted ? "yes" + (restrictions.isEmpty ? "" : ", restricts " + restrictions.joined(separator: ", ")) : "no"))
        lines.append(("Annotations", "\(annotations)"))
        lines.append(("Form fields", "\(fields)"))
        lines.append(("Outline", document.outlineRoot.map { $0.numberOfChildren > 0 ? "yes" : "no" } ?? "no"))
        let attributes = document.documentAttributes ?? [:]
        for (key, name) in [(PDFDocumentAttribute.producerAttribute, "Producer"), (.creatorAttribute, "Creator")] {
            if let value = attributes[key] as? String, !value.isEmpty { lines.append((name, value)) }
        }
        lines.append(("Unsaved changes", library.hasUnsavedChanges ? "yes" : "no"))
        return BugReport.Section(title: "Document", lines: lines)
    }

    /// This run's log lines from the app (macOS keeps only the current run's
    /// for an app to read), newest 300.
    private static func sessionLog() -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let predicate = NSPredicate(format: "subsystem == %@", "app.paperplane.reader")
        guard let entries = try? store.getEntries(matching: predicate) else { return [] }
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss.SSS"
        let lines = entries.compactMap { $0 as? OSLogEntryLog }.map { entry in
            "\(time.string(from: entry.date)) [\(entry.category)] \(level(entry.level)) \(entry.composedMessage)"
        }
        return Array(lines.suffix(300))
    }

    private static func level(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        default: "-"
        }
    }
}

struct BugReportWindow: View {
    @ObservedObject private var model = BugReportModel.shared
    @State private var showsReport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Describe what went wrong. The report below goes with it; nothing is sent until you choose how to send it."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(L("What happened?"))
                .font(.headline)
            editor($model.summary, height: 80)

            Text(L("Steps to reproduce (optional)"))
                .font(.headline)
            editor($model.steps, height: 60)

            VStack(alignment: .leading, spacing: 6) {
                Toggle(L("Include details of the open document (not its name or text)"), isOn: $model.includesDocument)
                    .disabled(model.documentSection == nil)
                if let crash = model.crash {
                    Toggle(L("Include the crash report from %@", crash.date.formatted(date: .abbreviated, time: .shortened)), isOn: $model.includesCrash)
                }
                Toggle(L("Include the app’s log of this session (%ld lines)", model.log.count), isOn: $model.includesLog)
                    .disabled(model.log.isEmpty)
                Text(L("Mac and app details are always included. The log can include the names of files you opened. If the problem is in a particular PDF, attach it to your email yourself if you can share it."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup(L("Show the Report"), isExpanded: $showsReport) {
                ScrollView {
                    Text(model.report.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 160, maxHeight: 260)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
            }

            if let status = model.status {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(L("Copy Report")) { model.copy() }
                Button(L("Save Report…")) { model.save() }
                Spacer()
                if BugReportDestination.issues != nil {
                    Button(L("Open Issue Page")) { model.openIssuePage() }
                        .disabled(!model.canSend)
                }
                if BugReportDestination.email != nil {
                    Button(L("Send by Email")) { model.sendByEmail() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canSend)
                }
            }
            if BugReportDestination.email == nil, BugReportDestination.issues == nil {
                Text(L("Copy or save the report, and send it to the developer."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func editor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.body)
            .frame(height: height)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
    }
}
