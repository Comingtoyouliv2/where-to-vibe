//
//  AmbitionLadder.swift
//  where-to-vibe
//
//  The differentiator: for a vague build request ("앱을 만들어줘"), instead of
//  just "be more specific", we surface an AMBITION LADDER — three tiers of how
//  far you could take the same idea, each revealing the tools/techniques a pro
//  would reach for that a beginner doesn't know to ask for.
//
//  This is the "you didn't know you could want this" gap that makes the coach
//  special. The content here is a curated seed (no API key, instant); later an
//  LLM can generate domain-specific ladders dynamically behind the same shape.
//

import SwiftUI

struct AmbitionTool: Identifiable {
    let id = UUID()
    let name: String
    let why: String
}

struct AmbitionTier: Identifiable {
    let id = UUID()
    let title: String
    let goal: String
    let tools: [AmbitionTool]
    let tint: Color
    let systemImage: String
}

enum AmbitionLadderLibrary {
    /// Returns a curated ambition ladder for a vague build request. For now we
    /// return a strong generic "make something" ladder; the hook is here for an
    /// LLM (or keyword routing) to produce domain-specific ladders later.
    static func ladder(for idea: String) -> [AmbitionTier] {
        return defaultLadder
    }

    static let defaultLadder: [AmbitionTier] = [
        AmbitionTier(
            title: "일단 동작",
            goal: "빠르게 작동하는 첫 버전",
            tools: [
                AmbitionTool(name: "AI에 바로 요청", why: "핵심 기능 1개부터")
            ],
            tint: Color(red: 0.55, green: 0.60, blue: 0.72),
            systemImage: "bolt.fill"
        ),
        AmbitionTier(
            title: "예쁘게",
            goal: "디자인된 제품 느낌",
            tools: [
                AmbitionTool(name: "Figma MCP", why: "디자인을 코드로 바로"),
                AmbitionTool(name: "Midjourney", why: "아이콘·이미지 생성"),
                AmbitionTool(name: "Tailwind · shadcn", why: "깔끔한 UI 기본기")
            ],
            tint: Color(red: 0.88, green: 0.56, blue: 0.32),
            systemImage: "paintbrush.fill"
        ),
        AmbitionTier(
            title: "진짜 제품",
            goal: "남들이 실제로 쓰는 제품",
            tools: [
                AmbitionTool(name: "Supabase", why: "로그인·데이터 저장"),
                AmbitionTool(name: "opencode · Claude Code", why: "멀티파일 에이전트"),
                AmbitionTool(name: "Vercel 배포", why: "세상에 공개")
            ],
            tint: Color(red: 0.46, green: 0.78, blue: 0.56),
            systemImage: "sparkles"
        )
    ]
}

/// Renders the three-tier ambition ladder as a card. Subviews are split out so
/// the SwiftUI type-checker stays fast.
struct AmbitionLadderView: View {
    let promptText: String
    let tiers: [AmbitionTier]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            HStack(alignment: .top, spacing: 12) {
                ForEach(tiers) { tier in
                    tierCard(tier)
                }
            }
            Text("같은 한 줄도, 어떤 도구를 쓰느냐에 따라 결과물이 완전히 달라져요.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(22)
        .frame(width: 640)
        .background(cardBackground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\"\(promptText)\"")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            Text("어디까지 만들고 싶어요?")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private func tierCard(_ tier: AmbitionTier) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: tier.systemImage)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(tier.tint.opacity(0.9)))
                Text(tier.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(tier.goal)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(tier.tools) { tool in
                    toolRow(tool, tint: tier.tint)
                }
            }
        }
        .padding(14)
        .frame(width: 188, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(tier.tint.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private func toolRow(_ tool: AmbitionTool, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(tool.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Text(tool.why)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 9)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(0.16))
        )
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.black.opacity(0.82))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 30, y: 14)
    }
}
