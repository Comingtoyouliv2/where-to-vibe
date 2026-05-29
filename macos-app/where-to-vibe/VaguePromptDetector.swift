import Foundation

struct VaguePromptSignal: Equatable {
    let isVague: Bool
    let score: Double
    let reason: String
    let missingAxes: [String]
}

final class VaguePromptDetector {
    private let englishVagueVerbs = [
        "make", "build", "create", "fix", "improve", "update", "change",
        "optimize", "refactor", "debug", "write", "generate", "help"
    ]
    private let koreanVagueVerbs = [
        "만들", "고쳐", "수정", "개선", "작성", "생성", "도와", "해줘",
        "하고 싶", "추천", "알려", "바꿔", "정리", "기획"
    ]

    private let englishVagueObjects = [
        "app", "website", "site", "page", "code", "bug", "thing", "feature",
        "ui", "design", "backend", "frontend", "prompt", "agent"
    ]
    private let koreanVagueObjects = [
        "앱", "웹", "사이트", "페이지", "코드", "버그", "기능", "디자인", "프롬프트",
        "서비스", "툴", "대시보드", "랜딩", "화면", "ui", "ux", "agent", "에이전트"
    ]

    func analyze(_ rawText: String, language: PromptLanguage) -> VaguePromptSignal {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return VaguePromptSignal(isVague: false, score: 0, reason: "", missingAxes: [])
        }

        let normalized = text.lowercased()
        let words = normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let koreanUnits = normalized
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        let effectiveWordCount = language == .korean && words.isEmpty ? koreanUnits.count : words.count

        var score = 0.0
        var missingAxes: [String] = []

        if effectiveWordCount <= 5 {
            score += 0.35
            missingAxes.append("goal")
        }

        let vagueVerbs = language == .english ? englishVagueVerbs : koreanVagueVerbs
        let vagueObjects = language == .english ? englishVagueObjects : koreanVagueObjects
        let targetUserTerms = language == .english
            ? ["for ", "user", "customer", "audience", "developer", "team"]
            : ["사용자", "유저", "고객", "타겟", "대상", "팀", "초보자", "입문자", "개발자", "디자이너", "학생", "직장인", "사람", "위한"]
        let successTerms = language == .english
            ? ["because", "so that", "goal", "expected", "done", "success"]
            : ["목표", "기대", "완료", "성공", "검증", "테스트", "확인", "동작", "결과", "되면", "해야"]
        let constraintTerms = language == .english
            ? ["must", "should", "avoid", "don't", "do not", "constraint", "only"]
            : ["반드시", "피해", "하지 말", "하지 않", "제약", "만 ", "없이", "우선", "먼저", "나중", "mvp", "간단", "작게"]
        let contextTerms = language == .english
            ? ["using", "with", "react", "swift", "supabase", "api", "database", "screen", "component"]
            : ["react", "swift", "supabase", "api", "db", "데이터", "화면", "컴포넌트", "기술", "스택", "로그", "에러", "스크린샷"]

        if words.contains(where: vagueVerbs.contains) || containsAny(normalized, vagueVerbs) {
            score += 0.18
        }

        if words.contains(where: vagueObjects.contains) || containsAny(normalized, vagueObjects) {
            score += 0.18
            missingAxes.append("scope")
        }

        if !containsAny(normalized, targetUserTerms) {
            score += 0.12
            missingAxes.append("target user")
        }

        if !containsAny(normalized, successTerms) {
            score += 0.1
            missingAxes.append("success criteria")
        }

        if !containsAny(normalized, constraintTerms) {
            score += 0.07
            missingAxes.append("constraints")
        }

        if !containsAny(normalized, contextTerms) {
            score += 0.05
            missingAxes.append("context")
        }

        let uniqueAxes = Array(NSOrderedSet(array: missingAxes)) as? [String] ?? missingAxes
        let cappedScore = min(adjustedScore(score, text: normalized, language: language), 1.0)
        let isVague = cappedScore >= 0.42

        return VaguePromptSignal(
            isVague: isVague,
            score: cappedScore,
            reason: reason(for: uniqueAxes, language: language),
            missingAxes: uniqueAxes
        )
    }

    private func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private func adjustedScore(_ score: Double, text: String, language: PromptLanguage) -> Double {
        guard language == .korean else { return score }

        var adjusted = score
        if containsAny(text, ["하고 싶어", "만들고 싶", "뭘 해야", "어떻게 해야", "잘 모르", "막막"]) {
            adjusted += 0.12
        }
        if containsAny(text, ["예를 들어", "구체적으로", "단계별", "요구사항", "완료 기준", "테스트"]) {
            adjusted -= 0.10
        }
        return max(0, adjusted)
    }

    private func reason(for axes: [String], language: PromptLanguage) -> String {
        guard !axes.isEmpty else {
            return language == .korean ? "조금 더 실행 가능한 형태로 좁히면 좋아요." : "This could be more executable."
        }

        let visibleAxes = axes.prefix(2).map { axisName($0, language: language) }
        let joined = visibleAxes.joined(separator: language == .korean ? "과 " : " and ")
        if language == .korean {
            return "\(joined)을 먼저 정하면 바로 실행 가능한 요청이 돼요."
        }
        return "This is missing \(joined)."
    }

    private func axisName(_ axis: String, language: PromptLanguage) -> String {
        guard language == .korean else { return axis }
        switch axis {
        case "goal": return "목표"
        case "scope": return "범위"
        case "target user": return "타겟 사용자"
        case "success criteria": return "완료 기준"
        case "constraints": return "제약 조건"
        case "context": return "맥락"
        default: return axis
        }
    }
}
