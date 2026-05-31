//
//  IdeaRefinementController.swift
//  where-to-vibe
//
//  A dedicated, multi-turn "idea refinement" chat opened from the menu bar.
//  The Companion asks ONE question at a time (LLM-generated, tailored to the
//  user's idea), shows running understanding, offers clickable choices AND a
//  manual text field (in case none of the choices fit), and finally produces a
//  structured, AI-ready prompt the user can copy.
//
//  Self-contained: its own NSWindow + view model + OpenAI chat-completions
//  call. Does not touch the cursor-side coaching path.
//

import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted by the menu-bar panel to open the idea-refinement chat.
    static let startIdeaRefinement = Notification.Name("startIdeaRefinement")
}

// MARK: - Controller (owns the window)

@MainActor
final class IdeaRefinementController: NSObject {
    private let appState: AppState
    private let model: IdeaRefinementModel
    private var window: NSWindow?

    init(appState: AppState) {
        self.appState = appState
        self.model = IdeaRefinementModel(appState: appState)
        super.init()
    }

    func show() {
        if window == nil {
            let hosting = NSHostingView(rootView: IdeaRefinementChatView(model: model))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "아이디어 구체화"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.startIfNeeded()
    }
}

// MARK: - View model + LLM loop

@MainActor
final class IdeaRefinementModel: ObservableObject {
    struct Understanding: Equatable {
        var productType: String?
        var user: String?
        var problem: String?
        var success: String?
        var constraints: String?
    }

    struct FinalResult: Equatable {
        var goal: String
        var targetUser: String
        var problem: String
        var successMetric: String
        var constraints: String
        var aiPrompt: String
    }

    @Published var understanding = Understanding()
    @Published var question: String = ""
    @Published var why: String = ""
    @Published var options: [String] = []
    @Published var manualInput: String = ""
    @Published var isLoading: Bool = false
    @Published var isDone: Bool = false
    @Published var finalResult: FinalResult?
    @Published var errorText: String?
    @Published var didCopy: Bool = false

    private let appState: AppState
    /// Full chat transcript sent to the model each turn (role/content pairs).
    private var messages: [[String: String]] = []
    private var hasStarted = false

    init(appState: AppState) {
        self.appState = appState
    }

    var isKorean: Bool { appState.promptLanguage == .korean }

    func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        messages = [["role": "user", "content": "시작합니다. 제 아이디어를 구체화하도록 도와주세요."]]
        Task { await requestNextStep() }
    }

    /// The user answered — by tapping a choice or typing their own text.
    func submit(_ answer: String) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isLoading else { return }
        manualInput = ""
        messages.append(["role": "user", "content": trimmed])
        Task { await requestNextStep() }
    }

    func restart() {
        hasStarted = false
        understanding = Understanding()
        question = ""; why = ""; options = []; manualInput = ""
        isDone = false; finalResult = nil; errorText = nil; didCopy = false
        messages = []
        startIfNeeded()
    }

    func copyFinalPrompt() {
        guard let prompt = finalResult?.aiPrompt else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.didCopy = false
        }
    }

    // MARK: LLM call

    private func requestNextStep() async {
        guard appState.hasOpenAIAPIKey else {
            errorText = "메뉴바 설정에서 OpenAI API Key를 먼저 입력해 주세요."
            return
        }
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            let step = try await callModel()
            apply(step)
            // Record the model's structured reply so the next turn has context.
            if let raw = step.rawJSON {
                messages.append(["role": "assistant", "content": raw])
            }
        } catch {
            errorText = isKorean
                ? "연결에 문제가 생겼어요. 잠시 후 다시 시도해 주세요. (\(error.localizedDescription))"
                : "Something went wrong. Please try again. (\(error.localizedDescription))"
        }
    }

    private func apply(_ step: StepResponse) {
        if let u = step.understanding {
            understanding = Understanding(
                productType: u.productType, user: u.user, problem: u.problem,
                success: u.success, constraints: u.constraints
            )
        }
        if step.done == true, let f = step.finalResult {
            isDone = true
            finalResult = FinalResult(
                goal: f.goal, targetUser: f.targetUser, problem: f.problem,
                successMetric: f.successMetric, constraints: f.constraints, aiPrompt: f.aiPrompt
            )
        } else {
            isDone = false
            question = step.question ?? ""
            why = step.why ?? ""
            options = step.options ?? []
        }
    }

    private func callModel() async throws -> StepResponse {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(appState.openAIAPIKey)", forHTTPHeaderField: "Authorization")

        var fullMessages: [[String: String]] = [["role": "system", "content": Self.systemPrompt(isKorean: isKorean)]]
        fullMessages.append(contentsOf: messages)

        let body: [String: Any] = [
            "model": "gpt-4.1",
            "response_format": ["type": "json_object"],
            "messages": fullMessages
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "IdeaRefinement", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: bodyText.prefix(120).description])
        }

        let envelope = try JSONDecoder().decode(ChatEnvelope.self, from: data)
        guard let content = envelope.choices.first?.message.content,
              let contentData = content.data(using: .utf8) else {
            throw NSError(domain: "IdeaRefinement", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "empty response"])
        }
        var step = try JSONDecoder().decode(StepResponse.self, from: contentData)
        step.rawJSON = content
        return step
    }

    // MARK: System prompt

    private static func systemPrompt(isKorean: Bool) -> String {
        // The Companion guides the user from a vague idea to an AI-ready prompt,
        // one question at a time, always returning a strict JSON object the app
        // renders. (The user may answer with a listed option OR free text.)
        return """
        당신은 Where-to-vibe의 AI Companion입니다. 사용자의 모호한 아이디어를, AI가 이해할 수
        있는 구체적인 Prompt로 발전시키는 학습 동반자입니다. 정답을 바로 주지 말고, 사용자가
        스스로 더 좋은 질문을 만들도록 도와주세요.

        대화 방식:
        - 한 번에 하나의 질문만 합니다.
        - 왜 이 질문을 하는지 'why'에 한 줄로 설명합니다.
        - 친절하고 쉬운 말. 평가하지 않습니다. 부담을 주지 않습니다.
        - 매 턴마다 지금까지 이해한 내용(understanding)을 채워서 보여줍니다.

        구체화 프레임워크 (이 항목들을 차례로 채워나갑니다):
        1) productType — 무엇을 만들고 싶은가
        2) user — 누가 사용하는가
        3) problem — 어떤 문제를 해결하는가
        4) success — 성공하면 어떤 모습인가
        5) constraints — 어떤 제약이 있는가 (플랫폼/기간 등)

        질문에는 항상 사용자가 고를 수 있는 구체적 보기(options) 3~5개를 제시하세요. 단, 사용자는
        보기에 없는 답을 직접 입력할 수도 있으니, 보기는 '예시'이지 강제가 아닙니다.

        충분히 모이면(보통 4~5개 항목) done=true 로 끝내고, AI가 바로 쓸 수 있는 최종 결과를
        final 에 채웁니다. aiPrompt 는 사용자가 그대로 복사해 AI 코딩 도구에 붙여넣을 수 있는,
        구체적이고 실행 가능한 한 문단의 프롬프트여야 합니다.

        반드시 아래 JSON 객체 '하나만' 반환하세요. 다른 텍스트/코드펜스 없이 JSON만:
        {
          "understanding": {
            "productType": string|null, "user": string|null, "problem": string|null,
            "success": string|null, "constraints": string|null
          },
          "done": boolean,
          "question": string|null,   // done=false 일 때, 다음 질문 하나
          "why": string|null,        // 이 질문을 하는 이유 한 줄
          "options": [string],       // 보기 3~5개 (없으면 빈 배열)
          "final": {                 // done=true 일 때만 채움, 아니면 null
            "goal": string, "targetUser": string, "problem": string,
            "successMetric": string, "constraints": string, "aiPrompt": string
          } | null
        }

        모든 사용자 대면 텍스트는 \(isKorean ? "한국어" : "영어")로, 자연스럽고 짧게 작성하세요.
        """
    }
}

// MARK: - Decodable shapes

private struct ChatEnvelope: Decodable {
    struct Choice: Decodable { let message: Message }
    struct Message: Decodable { let content: String? }
    let choices: [Choice]
}

struct StepResponse: Decodable {
    struct U: Decodable {
        var productType: String?
        var user: String?
        var problem: String?
        var success: String?
        var constraints: String?
    }
    struct Final: Decodable {
        var goal: String
        var targetUser: String
        var problem: String
        var successMetric: String
        var constraints: String
        var aiPrompt: String
    }

    var understanding: U?
    var done: Bool?
    var question: String?
    var why: String?
    var options: [String]?
    var finalResult: Final?

    /// Not from JSON — the raw content string, stored by the caller so it can
    /// be appended to the transcript.
    var rawJSON: String?

    enum CodingKeys: String, CodingKey {
        case understanding, done, question, why, options
        case finalResult = "final"
    }
}

// MARK: - Chat view

private struct IdeaRefinementChatView: View {
    @ObservedObject var model: IdeaRefinementModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.08))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    understandingCard
                    if let error = model.errorText {
                        errorBanner(error)
                    }
                    if model.isDone {
                        finalCard
                    } else {
                        questionSection
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 440, minHeight: 560)
        .background(Color(red: 0.09, green: 0.09, blue: 0.11))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor.opacity(0.85)))
            VStack(alignment: .leading, spacing: 1) {
                Text("아이디어 구체화")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("막연한 생각을 AI가 이해할 프롬프트로")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Button("처음부터") { model.restart() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Understanding (progress)

    private var understandingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("현재 이해한 내용")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            understandingRow("제품 종류", model.understanding.productType)
            understandingRow("사용자", model.understanding.user)
            understandingRow("문제", model.understanding.problem)
            understandingRow("성공 기준", model.understanding.success)
            understandingRow("제약", model.understanding.constraints)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 1))
        )
    }

    private func understandingRow(_ label: String, _ value: String?) -> some View {
        let filled = !(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: filled ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 12))
                .foregroundStyle(filled ? Color.green : .white.opacity(0.3))
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 64, alignment: .leading)
            Text(filled ? (value ?? "") : "?")
                .font(.system(size: 12))
                .foregroundStyle(filled ? .white : .white.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: Question + options + manual input

    @ViewBuilder
    private var questionSection: some View {
        if model.isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("생각하는 중…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }
            .padding(.vertical, 8)
        } else if !model.question.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.question)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.why.isEmpty {
                    Text("💡 \(model.why)")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.options, id: \.self) { option in
                    optionButton(option)
                }
                manualInputRow
            }
        }
    }

    private func optionButton(_ option: String) -> some View {
        Button { model.submit(option) } label: {
            HStack {
                Text(option)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.07))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var manualInputRow: some View {
        HStack(spacing: 8) {
            TextField("원하는 게 없으면 직접 입력…", text: $model.manualInput)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(0.05))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.accentColor.opacity(0.4), lineWidth: 1))
                )
                .onSubmit { model.submit(model.manualInput) }
            Button {
                model.submit(model.manualInput)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(model.manualInput.isEmpty ? Color.white.opacity(0.25) : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(model.manualInput.isEmpty)
            .pointerCursor()
        }
        .padding(.top, 4)
    }

    // MARK: Final result

    private var finalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("🎉 AI가 이해할 수 있는 수준으로 정리됐어요")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)

            if let result = model.finalResult {
                finalRow("Goal", result.goal)
                finalRow("Target User", result.targetUser)
                finalRow("Problem", result.problem)
                finalRow("Success", result.successMetric)
                finalRow("Constraints", result.constraints)

                Divider().overlay(.white.opacity(0.12))

                Text("AI Prompt")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Text(result.aiPrompt)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))

                Button { model.copyFinalPrompt() } label: {
                    Label(model.didCopy ? "복사됨!" : "AI Prompt 복사", systemImage: model.didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.9)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .pointerCursor()
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

    private func finalRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
