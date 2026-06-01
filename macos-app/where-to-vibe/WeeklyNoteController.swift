//
//  WeeklyNoteController.swift
//  where-to-vibe
//
//  "Weekly prompt note." Each time the coach analyzes a draft, we log which
//  prompt dimensions the user included (pros / strengths) and which they left
//  out (cons / things to improve). Once a week the user can open this note to
//  see, in plain language:
//    • what they're consistently doing well (Keep),
//    • what they keep forgetting (Improve), and
//    • one concrete direction to focus on next week.
//
//  Everything is LOCAL — a JSON file under Application Support. No server, no
//  network call: the note is computed from the on-disk habit log, so it's
//  instant and works offline.
//

import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// Posted by the menu-bar panel to open the weekly prompt note.
    static let showWeeklyNote = Notification.Name("showWeeklyNote")
}

/// The prompt-skill axes the weekly note reports on. Mirrors
/// `AppState.coachSkillAxes`, kept as a plain (nonisolated) constant so the
/// analysis can run off the main actor without isolation warnings.
let weeklyNoteSkillAxes: [String] = ["goal", "scope", "context", "constraints", "success criteria"]

// MARK: - Habit log (local, on disk)

/// One coached draft: which skill axes were present vs. missing. Dated so the
/// weekly note can window to the last 7 days.
struct PromptHabitEvent: Codable {
    let date: Date
    let presentAxes: [String]
    let missingAxes: [String]
}

/// Append-only (capped) log of coached-draft events. JSON under Application
/// Support — enough for a single-user menu-bar app.
final class PromptHabitStore {
    static let shared = PromptHabitStore()

    private let fileURL: URL
    private(set) var events: [PromptHabitEvent] = []

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("where-to-vibe", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("prompt-habits.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([PromptHabitEvent].self, from: data) else { return }
        events = decoded
    }

    /// Records one coached draft. Prunes anything older than 60 days and caps the
    /// log so the file never grows without bound.
    func add(presentAxes: [String], missingAxes: [String]) {
        events.append(PromptHabitEvent(date: Date(), presentAxes: presentAxes, missingAxes: missingAxes))
        let cutoff = Date().addingTimeInterval(-60 * 24 * 3600)
        events = events.filter { $0.date >= cutoff }
        if events.count > 1000 { events = Array(events.suffix(1000)) }
        if let data = try? JSONEncoder().encode(events) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Events from the last `days` days.
    func events(within days: Int) -> [PromptHabitEvent] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        return events.filter { $0.date >= cutoff }
    }
}

// MARK: - Analysis

struct WeeklyAxisStat: Identifiable {
    let axis: String
    let presentCount: Int
    let missingCount: Int
    var id: String { axis }
    var total: Int { presentCount + missingCount }
    var presentRatio: Double { total == 0 ? 0 : Double(presentCount) / Double(total) }
}

struct WeeklyAnalysis {
    let totalDrafts: Int
    let stats: [WeeklyAxisStat]
    let keepAxes: [String]      // consistently included → strengths
    let improveAxes: [String]   // frequently missing → things to work on
    let focusAxis: String?      // the single weakest axis to target next

    static let empty = WeeklyAnalysis(totalDrafts: 0, stats: [], keepAxes: [], improveAxes: [], focusAxis: nil)

    static func analyze(events: [PromptHabitEvent]) -> WeeklyAnalysis {
        var present: [String: Int] = [:]
        var missing: [String: Int] = [:]
        for event in events {
            for axis in event.presentAxes where weeklyNoteSkillAxes.contains(axis) {
                present[axis, default: 0] += 1
            }
            for axis in event.missingAxes where weeklyNoteSkillAxes.contains(axis) {
                missing[axis, default: 0] += 1
            }
        }
        let stats = weeklyNoteSkillAxes.map { axis in
            WeeklyAxisStat(axis: axis, presentCount: present[axis] ?? 0, missingCount: missing[axis] ?? 0)
        }
        // Strength: included at least 60% of the time (and actually seen).
        let keep = stats.filter { $0.total > 0 && $0.presentRatio >= 0.6 }.map { $0.axis }
        // To improve: missed often and not yet a strength. Top 2 by miss count.
        let improve = stats
            .filter { $0.missingCount > 0 && $0.presentRatio < 0.6 }
            .sorted { $0.missingCount > $1.missingCount }
            .prefix(2)
            .map { $0.axis }
        let focus = stats
            .filter { $0.missingCount > 0 }
            .max { $0.missingCount < $1.missingCount }?
            .axis
        return WeeklyAnalysis(
            totalDrafts: events.count,
            stats: stats,
            keepAxes: keep,
            improveAxes: Array(improve),
            focusAxis: focus
        )
    }
}

// MARK: - View model

@MainActor
final class WeeklyNoteModel: ObservableObject {
    @Published var analysis: WeeklyAnalysis = .empty
    @Published var isKorean = false
}

// MARK: - Controller

@MainActor
final class WeeklyNoteController: NSObject {
    private let appState: AppState
    private let model = WeeklyNoteModel()
    private var window: NSWindow?

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    func show() {
        model.isKorean = appState.promptLanguage == .korean
        model.analysis = WeeklyAnalysis.analyze(events: PromptHabitStore.shared.events(within: 7))

        if window == nil {
            let hosting = NSHostingView(rootView: WeeklyNoteView(model: model))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.title = model.isKorean ? "이번 주 프롬프트 노트" : "Weekly prompt note"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Copy helpers (axis → human label + concrete direction)

enum WeeklyNoteCopy {
    static func axisLabel(_ axis: String, isKorean: Bool) -> String {
        switch axis {
        case "goal": return isKorean ? "목표" : "Goal"
        case "scope": return isKorean ? "범위" : "Scope"
        case "context": return isKorean ? "맥락" : "Context"
        case "constraints": return isKorean ? "제약" : "Constraints"
        case "success criteria": return isKorean ? "완료 기준" : "Done-when"
        default: return axis
        }
    }

    static func axisIcon(_ axis: String) -> String {
        switch axis {
        case "goal": return "🎯"
        case "scope": return "🧩"
        case "context": return "🧭"
        case "constraints": return "⛔️"
        case "success criteria": return "✅"
        default: return "•"
        }
    }

    /// A short, concrete direction for fixing a frequently-missed axis.
    static func improveTip(_ axis: String, isKorean: Bool) -> String {
        switch axis {
        case "goal":
            return isKorean
                ? "무엇을 만들고 싶은지 한 문장으로 먼저 적어보세요. 예: \"OO를 하는 OO를 만들고 싶어요.\""
                : "Open with one sentence on what you want. e.g. \"I want to build a X that does Y.\""
        case "scope":
            return isKorean
                ? "이번에 할 것과 하지 않을 것을 나눠 적어보세요. 범위를 좁히면 AI가 덜 헤매요."
                : "Split what's in vs. out of scope. A narrower ask keeps the AI on track."
        case "context":
            return isKorean
                ? "어떤 환경·기술·대상인지 알려주세요. 예: \"React 웹앱\", \"초보자용\"."
                : "Name the setting/stack/audience. e.g. \"a React web app\", \"for beginners\"."
        case "constraints":
            return isKorean
                ? "꼭 지켜야 할 제약을 적어보세요. 예: \"새 라이브러리 금지\", \"한국어로\"."
                : "Spell out hard constraints. e.g. \"no new libraries\", \"answer in Korean\"."
        case "success criteria":
            return isKorean
                ? "무엇이 되면 \"완성\"인지 적어보세요. 예: \"버튼을 누르면 저장되면 끝\"."
                : "Say what \"done\" looks like. e.g. \"pressing the button saves — that's done.\""
        default:
            return ""
        }
    }

    /// A short affirmation for an axis the user includes consistently.
    static func keepTip(_ axis: String, isKorean: Bool) -> String {
        switch axis {
        case "goal":
            return isKorean ? "목표를 늘 분명히 적고 있어요." : "You consistently state a clear goal."
        case "scope":
            return isKorean ? "범위를 잘 좁혀서 요청해요." : "You scope your asks tightly."
        case "context":
            return isKorean ? "맥락을 충분히 제공해요." : "You give enough context."
        case "constraints":
            return isKorean ? "제약을 빠뜨리지 않아요." : "You rarely forget constraints."
        case "success criteria":
            return isKorean ? "완료 기준을 분명히 적어요." : "You state clear done-criteria."
        default:
            return ""
        }
    }
}

// MARK: - Window view

private struct WeeklyNoteView: View {
    @ObservedObject var model: WeeklyNoteModel

    private var isKorean: Bool { model.isKorean }
    private var analysis: WeeklyAnalysis { model.analysis }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.08))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if analysis.totalDrafts == 0 {
                        emptyHint
                    } else {
                        summaryLine
                        keepSection
                        improveSection
                        focusCard
                        breakdownSection
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 420, minHeight: 480)
        .background(Color(red: 0.09, green: 0.09, blue: 0.11))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color(red: 0.86, green: 0.45, blue: 0.28)))
            VStack(alignment: .leading, spacing: 1) {
                Text(isKorean ? "이번 주 프롬프트 노트" : "Weekly prompt note")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(isKorean ? "최근 7일, 더 잘 쓰는 방향" : "Last 7 days · how to write better")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isKorean ? "아직 이번 주 데이터가 부족해요." : "Not enough data this week yet.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text(isKorean
                 ? "프롬프트를 몇 번 작성하면, 잘하고 있는 점과 개선하면 좋은 점을 정리해 드릴게요."
                 : "Write a few prompts and I'll summarize what you're doing well and what to improve.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summaryLine: some View {
        Text(isKorean
             ? "이번 주 \(analysis.totalDrafts)개의 프롬프트를 살펴봤어요."
             : "Reviewed \(analysis.totalDrafts) prompts this week.")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.7))
    }

    @ViewBuilder private var keepSection: some View {
        if !analysis.keepAxes.isEmpty {
            sectionCard(
                title: isKorean ? "유지하면 좋은 점 (Keep)" : "Keep doing this (Keep)",
                tint: .green
            ) {
                ForEach(analysis.keepAxes, id: \.self) { axis in
                    tipRow(
                        icon: WeeklyNoteCopy.axisIcon(axis),
                        label: WeeklyNoteCopy.axisLabel(axis, isKorean: isKorean),
                        detail: WeeklyNoteCopy.keepTip(axis, isKorean: isKorean),
                        tint: .green
                    )
                }
            }
        }
    }

    @ViewBuilder private var improveSection: some View {
        if !analysis.improveAxes.isEmpty {
            sectionCard(
                title: isKorean ? "개선하면 좋은 점 (Improve)" : "Worth improving (Improve)",
                tint: .orange
            ) {
                ForEach(analysis.improveAxes, id: \.self) { axis in
                    tipRow(
                        icon: WeeklyNoteCopy.axisIcon(axis),
                        label: WeeklyNoteCopy.axisLabel(axis, isKorean: isKorean),
                        detail: WeeklyNoteCopy.improveTip(axis, isKorean: isKorean),
                        tint: .orange
                    )
                }
            }
        }
    }

    @ViewBuilder private var focusCard: some View {
        if let focus = analysis.focusAxis {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "target")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 3) {
                    Text(isKorean ? "이번 주 한 가지 목표" : "One focus this week")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.cyan)
                    Text(isKorean
                         ? "\(WeeklyNoteCopy.axisLabel(focus, isKorean: true))부터 챙겨보기 — \(WeeklyNoteCopy.improveTip(focus, isKorean: true))"
                         : "Start with \(WeeklyNoteCopy.axisLabel(focus, isKorean: false)) — \(WeeklyNoteCopy.improveTip(focus, isKorean: false))")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.cyan.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.cyan.opacity(0.3), lineWidth: 1))
            )
        }
    }

    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isKorean ? "스킬별 현황" : "By skill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            ForEach(analysis.stats) { stat in
                HStack(spacing: 8) {
                    Text(WeeklyNoteCopy.axisIcon(stat.axis))
                        .font(.system(size: 12))
                    Text(WeeklyNoteCopy.axisLabel(stat.axis, isKorean: isKorean))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 90, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.10))
                            Capsule()
                                .fill(stat.presentRatio >= 0.6 ? Color.green.opacity(0.8) : Color.orange.opacity(0.8))
                                .frame(width: proxy.size.width * CGFloat(stat.presentRatio))
                        }
                    }
                    .frame(height: 6)
                    Text(stat.total == 0 ? "—" : "\(Int(stat.presentRatio * 100))%")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05)))
    }

    // MARK: Reusable pieces

    private func sectionCard<Content: View>(
        title: String, tint: Color, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(tint.opacity(0.2), lineWidth: 1))
        )
    }

    private func tipRow(icon: String, label: String, detail: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(icon)
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
