//
//  ScreenStabilityDetector.swift
//  where-to-vibe
//
//  Decides WHEN it's appropriate to run proactive screen coaching. The problem
//  it solves: right after the user sends a message, the AI streams its answer
//  in token by token. If we read the screen during that, we'd be reacting to a
//  half-written answer and popping advice mindlessly.
//
//  The detector compares two tiny grayscale fingerprints of the cursor screen
//  taken a short interval apart:
//    • If they DIFFER, the screen is still changing (AI is generating) → wait.
//    • If they MATCH, the screen has settled (answer is complete) → it's safe to
//      read the whole answer and run the summarize/advice flow.
//  It also remembers the screen it last advised on, so it doesn't keep
//  re-advising the same unchanged answer.
//

import AppKit
import CoreGraphics

@MainActor
final class ScreenStabilityDetector {
    /// Side length of the downsampled fingerprint. Small enough to ignore JPEG
    /// noise, large enough that streaming text moves the numbers.
    private let fingerprintSide = 32

    /// Per-pixel mean absolute difference (0...255) at or below which two frames
    /// count as "the same screen" (not actively changing). Tuned so a blinking
    /// caret or clock tick stays under it, but streaming text goes over it.
    private let stableThreshold: Double = 3.0

    /// A change larger than this since the screen we last advised on means a
    /// genuinely new screen worth a fresh round of advice.
    private let noveltyThreshold: Double = 6.0

    /// Fingerprint of the screen we last produced advice for, so we don't keep
    /// re-advising an unchanged answer. nil until the first advice is shown.
    private var lastAdvisedFingerprint: [UInt8]?

    /// Captures the cursor screen and reduces it to a small grayscale
    /// fingerprint. Returns nil if screen-recording permission or capture failed.
    func captureFingerprint() async -> [UInt8]? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        guard let captures = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG() else {
            return nil
        }
        let cursorScreenCapture = captures.first(where: \.isCursorScreen) ?? captures.first
        guard let cursorScreenCapture,
              let cgImage = Self.decodeCGImage(from: cursorScreenCapture.imageData) else {
            return nil
        }
        return Self.fingerprint(from: cgImage, side: fingerprintSide)
    }

    /// True when two fingerprints are close enough that the screen is considered
    /// settled (the AI is no longer streaming).
    func isStable(_ first: [UInt8], _ second: [UInt8]) -> Bool {
        Self.meanAbsoluteDifference(first, second) <= stableThreshold
    }

    /// True when this screen is meaningfully different from the last one we
    /// advised on (or there is no prior advised screen yet).
    func isNovelComparedToLastAdvised(_ fingerprint: [UInt8]) -> Bool {
        guard let lastAdvisedFingerprint else { return true }
        return Self.meanAbsoluteDifference(fingerprint, lastAdvisedFingerprint) >= noveltyThreshold
    }

    /// Remembers the screen we just advised on. Call only after advice is
    /// actually shown, so a screen we stayed silent on can still be advised later.
    func recordAdvised(_ fingerprint: [UInt8]) {
        lastAdvisedFingerprint = fingerprint
    }

    /// Forgets the last advised screen, so the next settled screen is treated as
    /// novel. Call when the context changes (frontmost app switch, message sent).
    func reset() {
        lastAdvisedFingerprint = nil
    }

    // MARK: - Pixel helpers

    private static func decodeCGImage(from jpegData: Data) -> CGImage? {
        NSBitmapImageRep(data: jpegData)?.cgImage
    }

    /// Downsamples the image to side×side grayscale and returns the raw luminance
    /// bytes (one UInt8 per pixel).
    private static func fingerprint(from cgImage: CGImage, side: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: side * side)
        let grayColorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side,
            space: grayColorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixels
    }

    /// Average absolute per-pixel difference (0...255). Larger = more changed.
    private static func meanAbsoluteDifference(_ first: [UInt8], _ second: [UInt8]) -> Double {
        guard first.count == second.count, !first.isEmpty else {
            return .greatestFiniteMagnitude
        }
        var totalDifference = 0
        for index in first.indices {
            totalDifference += abs(Int(first[index]) - Int(second[index]))
        }
        return Double(totalDifference) / Double(first.count)
    }
}
