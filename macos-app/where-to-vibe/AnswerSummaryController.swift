//
//  AnswerSummaryController.swift
//  where-to-vibe
//
//  "Summarize the AI's answer." When the user has received a long reply from
//  Claude/ChatGPT/etc., they hit a hotkey (⌃⌥S) or the menu button and we:
//    1. Grab the answer — the current text selection (via a synthesized ⌘C,
//       restoring the clipboard afterwards), or a screenshot as a fallback.
//    2. Ask the LLM for a beginner-friendly summary (TL;DR + key points + a
//       suggested next step).
//    3. Show it in a small window and append it to a local history (journal).
//
//  Tracking is LOCAL only — a JSON file under Application Support. No server DB.
//  Self-contained: its own window + capture + OpenAI call + journal store.
//

import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// Posted by the menu-bar panel to summarize the current AI answer.
    static let summarizeAIAnswer = Notification.Name("summarizeAIAnswer")
}

// MARK: - Local journal (history)

struct CoachJournalEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let tldr: String
    let bullets: [String]
    let nextStep: String?
}

/// Local, on-disk history of answer summaries. JSON under Application Support —
/// enough for a single-user menu-bar app; swap for SQLite if it ever grows.
final class CoachJournalStore {
    static let shared = CoachJournalStore()

    private let fileURL: URL
    private(set) var entries: [CoachJournalEntry] = []

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("where-to-vibe", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("answer-journal.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([CoachJournalEntry].self, from: data) else { return }
        entries = decoded
    }

    func add(_ entry: CoachJournalEntry) {
        entries.insert(entry, at: 0)
        if entries.count > 100 { entries = Array(entries.prefix(100)) }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - View model

@MainActor
final class AnswerSummaryModel: ObservableObject {
    @Published var isLoading = false
    @Published var tldr = ""
    @Published var bullets: [String] = []
    @Published var nextStep: String?
    @Published var errorText: String?
    @Published var history: [CoachJournalEntry] = []

    func reset() {
        isLoading = true
        tldr = ""; bullets = []; nextStep = nil; errorText = nil
    }
}

// MARK: - Controller

@MainActor
final class AnswerSummaryController: NSObject {
    private let appState: AppState
    private let model = AnswerSummaryModel()
    private var window: NSWindow?
    private var hotkeyMonitor: Any?

    init(appState: AppState) {
        self.appState = appState
        super.init()
        installHotkey()
    }

    /// ⌃⌥S anywhere — summarize the current selection in the frontmost app.
    private func installHotkey() {
        hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            // keyCode 0x01 == "S"
            guard event.keyCode == 0x01, mods == [.control, .option] else { return }
            Task { @MainActor in await self?.summarize(useSelection: true) }
        }
    }

    /// Triggered from the menu button. Clicking the menu activates our app, so
    /// a synthesized ⌘C would copy nothing — use a screenshot instead.
    func summarizeFromMenu() {
        Task { @MainActor in await summarize(useSelection: false) }
    }

    // MARK: Flow

    private func summarize(useSelection: Bool) async {
        showWindow()
        model.reset()

        guard appState.hasOpenAIAPIKey else {
            model.errorText = "메뉴바 설정에서 OpenAI API Key를 먼저 입력해 주세요."
            model.isLoading = false
            return
        }

        var answerText: String?
        if useSelection {
            answerText = await copySelectedText()
        }
        let imageDataURL: String? = (answerText?.isEmpty ?? true) ? captureScreenDataURL() : nil

        if (answerText?.isEmpty ?? true) && imageDataURL == nil {
            model.errorText = "요약할 내용을 찾지 못했어요. 답변을 드래그해 선택한 뒤 다시 시도해 주세요."
            model.isLoading = false
            return
        }

        do {
            let summary = try await requestSummary(text: answerText, imageDataURL: imageDataURL)
            model.tldr = summary.tldr
            model.bullets = summary.bullets
            model.nextStep = summary.nextStep
            let entry = CoachJournalEntry(id: UUID(), date: Date(), tldr: summary.tldr,
                                          bullets: summary.bullets, nextStep: summary.nextStep)
            CoachJournalStore.shared.add(entry)
            model.history = CoachJournalStore.shared.entries
        } catch {
            model.errorText = "요약에 실패했어요. 잠시 후 다시 시도해 주세요. (\(error.localizedDescription))"
        }
        model.isLoading = false
    }

    // MARK: Capture

    /// Synthesizes ⌘C to copy the frontmost app's selection, reads it, then
    /// restores the user's previous clipboard so we don't clobber it.
    private func copySelectedText() async -> String? {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        let beforeCount = pasteboard.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        let keyC: CGKeyCode = 0x08
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        try? await Task.sleep(nanoseconds: 160_000_000)

        let copied: String? = (pasteboard.changeCount != beforeCount) ? pasteboard.string(forType: .string) : nil
        // Restore the prior clipboard contents.
        if pasteboard.changeCount != beforeCount {
            pasteboard.clearContents()
            if let previous { pasteboard.setString(previous, forType: .string) }
        }
        let trimmed = copied?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    private func captureScreenDataURL() -> String? {
        guard let cgImage = CGDisplayCreateImage(CGMainDisplayID()) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.5]) else { return nil }
        return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
    }

    // MARK: Window

    private func showWindow() {
        if window == nil {
            let hosting = NSHostingView(rootView: AnswerSummaryView(model: model))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.title = "AI 답변 요약"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.center()
            self.window = window
        }
        model.history = CoachJournalStore.shared.entries
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: LLM

    private struct Summary { let tldr: String; let bullets: [String]; let nextStep: String? }

    private func requestSummary(text: String?, imageDataURL: String?) async throws -> Summary {
        let isKorean = appState.promptLanguage == .korean
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(appState.openAIAPIKey)", forHTTPHeaderField: "Authorization")

        let system = """
        당신은 AI(예: Claude/ChatGPT)가 사용자에게 준 길고 복잡한 답변을, 비전문가도 30초 안에
        이해할 수 있게 요약하는 도우미입니다. 과장하지 말고, 답변에 실제로 있는 내용만 사용하세요.
        반드시 아래 JSON 하나만 반환하세요:
        {
          "tldr": string,          // 한 문장 핵심 요약
          "bullets": [string],     // 핵심 포인트 3~5개, 각 한 줄
          "nextStep": string|null  // 사용자가 다음에 하면 좋은 행동 한 가지 (없으면 null)
        }
        모든 텍스트는 \(isKorean ? "한국어" : "영어")로, 쉽고 짧게 작성하세요.
        """

        var userContent: Any
        if let text, !text.isEmpty {
            userContent = "다음 AI 답변을 요약해줘:\n\n\(text)"
        } else {
            // Vision: summarize what's visible (the AI's answer on screen).
            userContent = [
                ["type": "text", "text": "화면에 보이는 AI의 답변을 요약해줘."],
                ["type": "image_url", "image_url": ["url": imageDataURL ?? ""]]
            ] as [[String: Any]]
        }

        let body: [String: Any] = [
            "model": "gpt-4.1",
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userContent]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "AnswerSummary", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: bodyText.prefix(120).description])
        }
        let envelope = try JSONDecoder().decode(SummaryEnvelope.self, from: data)
        guard let content = envelope.choices.first?.message.content,
              let contentData = content.data(using: .utf8) else {
            throw NSError(domain: "AnswerSummary", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "empty response"])
        }
        let decoded = try JSONDecoder().decode(SummaryJSON.self, from: contentData)
        return Summary(tldr: decoded.tldr, bullets: decoded.bullets ?? [], nextStep: decoded.nextStep)
    }

    private struct SummaryEnvelope: Decodable {
        struct Choice: Decodable { let message: Message }
        struct Message: Decodable { let content: String? }
        let choices: [Choice]
    }
    private struct SummaryJSON: Decodable {
        let tldr: String
        let bullets: [String]?
        let nextStep: String?
    }
}

// MARK: - Window view

private struct AnswerSummaryView: View {
    @ObservedObject var model: AnswerSummaryModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.08))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.isLoading {
                        loadingRow
                    } else if let error = model.errorText {
                        errorBanner(error)
                    } else if !model.tldr.isEmpty {
                        summaryCard
                    } else {
                        emptyHint
                    }
                    if !model.history.isEmpty {
                        historySection
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 400, minHeight: 460)
        .background(Color(red: 0.09, green: 0.09, blue: 0.11))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.append")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor.opacity(0.85)))
            VStack(alignment: .leading, spacing: 1) {
                Text("AI 답변 요약")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("긴 답변을 30초 만에 이해하게")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("요약하는 중…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
        }
    }

    private var emptyHint: some View {
        Text("Claude·ChatGPT 등에서 답변을 드래그해 선택한 뒤 ⌃⌥S 를 누르면 이 답변을 요약해 드려요.")
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.tldr)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            if !model.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(model.bullets.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•").foregroundStyle(Color.accentColor)
                            Text(point).foregroundStyle(.white.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 13))
                    }
                }
            }
            if let nextStep = model.nextStep, !nextStep.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.right.circle.fill").foregroundStyle(.green)
                    Text("다음 단계: \(nextStep)")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.accentColor.opacity(0.25), lineWidth: 1))
        )
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("히스토리")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            ForEach(model.history) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.tldr)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.04)))
            }
        }
    }

    private func errorBanner(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.red.opacity(0.4)))
    }
}
