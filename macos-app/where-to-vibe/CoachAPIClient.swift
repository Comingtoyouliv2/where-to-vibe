//
//  CoachAPIClient.swift
//  where-to-vibe
//
//  Thin client for the where-to-vibe Cloudflare Worker's /coach
//  endpoint. Sends one or more JPEG screenshots (base64) plus optional
//  client hints, and parses the structured JSON response the worker
//  returns:
//
//      {
//        "mode":    "prompt_coach" | "vague_build_me" |
//                   "empty_context_next_step" | "error_first_cause" |
//                   "diff_review" | "none",
//        "nudge":   "<= 2 sentence advice, plain text",
//        "rewrite": "optional better prompt (string) — may be missing",
//        "checks":  ["how to verify success", ...] | null,
//        "point":   [x, y, "label"] | null,
//        "warnings": ["server-side karpathy-rule warnings", ...]
//      }
//
//  The worker contract is defined in worker/src/index.ts and the response
//  shape in worker/src/validators.ts.
//
//  This client is intentionally tiny: no streaming, no retries (the worker
//  already does one repair attempt internally), no caching. The caller
//  (AutoCoachObserver) handles dedupe and rate-limiting.
//

import Foundation

/// Plain Swift mirror of the worker's CoachResponse type. We accept the
/// JSON loosely (most fields optional) because the worker's validator
/// already enforces the contract — defending against malformed responses
/// twice would just hide bugs.
struct CoachResponse: Decodable {
    let mode: String
    let nudge: String
    let rewrite: String?
    let checks: [String]?
    /// Worker sends [x, y, "label"] as a heterogenous array; we decode it
    /// manually below to keep the model honest. nil when no point.
    let point: PointHint?
    let warnings: [String]?

    struct PointHint: Decodable {
        let x: Double
        let y: Double
        let label: String

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            self.x = try container.decode(Double.self)
            self.y = try container.decode(Double.self)
            self.label = try container.decode(String.self)
        }
    }
}

/// Hints we can send to short-circuit the worker's mode classifier. These
/// are best-effort — the worker treats missing hints as "I don't know".
/// Keys match the ClientHints type in worker/src/triggers.ts.
struct CoachClientHints: Encodable {
    /// Bundle ID or process name of the frontmost app at the moment of capture.
    /// Used by the worker to skip the model when it's obvious (e.g. Terminal →
    /// error_first_cause is likely).
    let frontmostBundleID: String?
    /// Human-readable app name, useful when bundle IDs are unavailable or when
    /// the worker wants to infer AI-chat contexts from app names.
    let frontAppName: String?
    /// True when the visible AI-chat input had stable text for ≥ 3-4s.
    let typingPaused: Bool?
    /// Why the client fired the request. `idle` lets the worker know this may
    /// be a proactive next-step suggestion rather than a user-requested answer.
    let triggerSource: String?

    enum CodingKeys: String, CodingKey {
        case frontmostBundleID = "frontmostBundleId"
        case frontAppName, typingPaused, triggerSource
    }
}

/// Errors surfaced from /coach calls. The observer logs these and quietly
/// drops the round-trip — we never bubble worker errors up to the user.
enum CoachAPIError: Error, CustomStringConvertible {
    case invalidURL(String)
    case transport(Error)
    case httpStatus(Int, String)
    case decode(Error, String)

    var description: String {
        switch self {
        case .invalidURL(let s): return "invalid worker URL: \(s)"
        case .transport(let e): return "transport: \(e.localizedDescription)"
        case .httpStatus(let c, let b): return "http \(c): \(b.prefix(200))"
        case .decode(let e, let raw): return "decode: \(e) — raw: \(raw.prefix(200))"
        }
    }
}

/// Posts one /coach request and returns the parsed CoachResponse. The
/// `screenshotsJPEG` array is the raw JPEG bytes for each attached screen
/// — we base64-encode at the boundary so callers don't have to.
@MainActor
final class CoachAPIClient {
    private let workerBaseURL: String
    private let urlSession: URLSession

    init(workerBaseURL: String, urlSession: URLSession = .shared) {
        self.workerBaseURL = workerBaseURL
        self.urlSession = urlSession
    }

    func requestCoachAdvice(
        screenshotsJPEG: [(jpegData: Data, label: String?)],
        userText: String?,
        hints: CoachClientHints?
    ) async -> Result<CoachResponse, CoachAPIError> {
        guard let url = URL(string: "\(workerBaseURL)/coach") else {
            return .failure(.invalidURL(workerBaseURL))
        }

        // The /coach worker route is the only one we actually call. /chat
        // exists too but is upstream-Where-to-vibe's prose endpoint; we ignore it.
        let encodedScreenshots: [[String: String]] = screenshotsJPEG.map { entry in
            var dict: [String: String] = ["base64": entry.jpegData.base64EncodedString()]
            if let label = entry.label { dict["label"] = label }
            return dict
        }

        var bodyDict: [String: Any] = ["screenshots": encodedScreenshots]
        if let userText, !userText.isEmpty {
            bodyDict["userText"] = userText
        }
        if let hints {
            // Encode hints by round-tripping through JSONEncoder so the
            // CodingKeys remap (frontmostBundleID -> frontmostBundleId) is
            // applied. Worker expects the lowercase-d form.
            if let hintsData = try? JSONEncoder().encode(hints),
               let hintsDict = try? JSONSerialization.jsonObject(with: hintsData) as? [String: Any] {
                bodyDict["hints"] = hintsDict
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The worker turns around one Claude vision call; 60s upper bound
        // covers cold-start + repair retry + slow LLM days.
        request.timeoutInterval = 60

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
        } catch {
            return .failure(.transport(error))
        }

        do {
            let (responseData, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.httpStatus(0, "no http response"))
            }
            if httpResponse.statusCode != 200 {
                let body = String(data: responseData, encoding: .utf8) ?? "<binary>"
                return .failure(.httpStatus(httpResponse.statusCode, body))
            }
            do {
                let decoded = try JSONDecoder().decode(CoachResponse.self, from: responseData)
                return .success(decoded)
            } catch {
                let rawBody = String(data: responseData, encoding: .utf8) ?? "<binary>"
                return .failure(.decode(error, rawBody))
            }
        } catch {
            return .failure(.transport(error))
        }
    }

    // MARK: - Streaming variant

    /// Events emitted while a /coach-stream request is in progress. The
    /// observer consumes these to drive the bubble's typewriter UI as
    /// tokens arrive, then finalize with the full structured response.
    enum CoachStreamEvent {
        /// The nudge field's value has grown — the full text revealed so
        /// far (not a delta). The observer should pass this straight to
        /// the bubble's typewriter model. Fires many times during a call.
        case partialNudge(nudgeSoFar: String)
        /// The rewrite field's value has grown. Same shape as
        /// `partialNudge` but for the spec / rewrite block. Fires
        /// repeatedly while the model streams the rewrite. We emit a
        /// separate event (rather than reusing partialNudge) so the
        /// bubble view can render nudge above and rewrite below in
        /// their own typewriter regions.
        case partialRewrite(rewriteSoFar: String)
        /// The full Anthropic stream finished and we parsed the JSON
        /// envelope successfully. Includes rewrite + mode + checks etc.
        case completed(CoachResponse)
        /// Something went wrong. The bubble should leave whatever
        /// partial nudge it already has on screen (it's still useful)
        /// and just stop expecting more tokens.
        case failed(CoachAPIError)
    }

    /// Streaming variant of `requestCoachAdvice`. Hits the worker's
    /// `/coach-stream` route which proxies Anthropic's native SSE. The
    /// returned AsyncStream emits partial nudge text as tokens arrive,
    /// then finishes with a `.completed` (or `.failed`) event.
    ///
    /// The caller is responsible for cancelling the consuming task if
    /// the user dismisses the bubble early.
    func requestCoachAdviceStreaming(
        screenshotsJPEG: [(jpegData: Data, label: String?)],
        userText: String?,
        hints: CoachClientHints?
    ) -> AsyncStream<CoachStreamEvent> {
        AsyncStream { continuation in
            Task {
                await self.runStreamingRequest(
                    screenshotsJPEG: screenshotsJPEG,
                    userText: userText,
                    hints: hints,
                    continuation: continuation
                )
            }
        }
    }

    private func runStreamingRequest(
        screenshotsJPEG: [(jpegData: Data, label: String?)],
        userText: String?,
        hints: CoachClientHints?,
        continuation: AsyncStream<CoachStreamEvent>.Continuation
    ) async {
        guard let url = URL(string: "\(workerBaseURL)/coach-stream") else {
            continuation.yield(.failed(.invalidURL(workerBaseURL)))
            continuation.finish()
            return
        }

        let encodedScreenshots: [[String: String]] = screenshotsJPEG.map { entry in
            var dict: [String: String] = ["base64": entry.jpegData.base64EncodedString()]
            if let label = entry.label { dict["label"] = label }
            return dict
        }
        var bodyDict: [String: Any] = ["screenshots": encodedScreenshots]
        if let userText, !userText.isEmpty {
            bodyDict["userText"] = userText
        }
        if let hints,
           let hintsData = try? JSONEncoder().encode(hints),
           let hintsDict = try? JSONSerialization.jsonObject(with: hintsData) as? [String: Any] {
            bodyDict["hints"] = hintsDict
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
        } catch {
            continuation.yield(.failed(.transport(error)))
            continuation.finish()
            return
        }

        // Accumulator for the full text body as tokens arrive. We
        // incrementally scan this for both the nudge and rewrite fields
        // and yield .partialNudge / .partialRewrite each time either
        // grows. When the stream ends we pull the final JSON out of
        // the same buffer.
        var accumulatedAssistantText = ""
        var lastEmittedNudgeText = ""
        var lastEmittedRewriteText = ""
        var leftoverLineBuffer = ""

        do {
            let (bytes, response) = try await urlSession.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                continuation.yield(.failed(.httpStatus(0, "no http response")))
                continuation.finish()
                return
            }
            if httpResponse.statusCode != 200 {
                // Drain the body for error reporting, then bail.
                var errorBodyBytes = Data()
                for try await byte in bytes {
                    errorBodyBytes.append(byte)
                    if errorBodyBytes.count > 4096 { break }
                }
                let errorBodyString = String(data: errorBodyBytes, encoding: .utf8) ?? "<binary>"
                continuation.yield(.failed(.httpStatus(httpResponse.statusCode, errorBodyString)))
                continuation.finish()
                return
            }

            // Iterate the byte stream line-by-line. The .lines API does
            // newline splitting for us, which is exactly what SSE needs
            // (events are separated by "\n\n", lines by "\n").
            var streamSeenEventTypeCounts: [String: Int] = [:]
            for try await line in bytes.lines {
                // SSE frame format:
                //   event: content_block_delta
                //   data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello"}}
                // We only care about `data:` lines that contain text deltas.
                guard line.hasPrefix("data: ") else { continue }
                let payloadString = String(line.dropFirst("data: ".count))
                guard !payloadString.isEmpty, payloadString != "[DONE]" else { continue }

                guard let payloadData = payloadString.data(using: .utf8),
                      let payloadObject = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
                else { continue }

                let eventType = payloadObject["type"] as? String
                if let eventType {
                    streamSeenEventTypeCounts[eventType, default: 0] += 1
                }

                // Anthropic SSE event types we care about:
                //   - content_block_delta: a text token has arrived
                //   - message_stop: stream complete
                if eventType == "content_block_delta",
                   let delta = payloadObject["delta"] as? [String: Any],
                   let deltaText = delta["text"] as? String {
                    accumulatedAssistantText.append(deltaText)
                    leftoverLineBuffer = accumulatedAssistantText

                    // Try to extract the current state of the nudge AND
                    // rewrite fields. While the JSON is still streaming
                    // in, either string may be partial — that's fine, we
                    // want to show it anyway so the user sees characters
                    // as they arrive. nudge typically appears in the
                    // stream before rewrite (we ordered the schema that
                    // way in the system prompt), so its callback fires
                    // first; rewrite's callback joins in once the model
                    // gets to that field.
                    if let nudgeSoFar = extractPartialStringField(
                        named: "nudge",
                        fromPartialJSON: accumulatedAssistantText
                    ), nudgeSoFar != lastEmittedNudgeText {
                        lastEmittedNudgeText = nudgeSoFar
                        continuation.yield(.partialNudge(nudgeSoFar: nudgeSoFar))
                    }
                    if let rewriteSoFar = extractPartialStringField(
                        named: "rewrite",
                        fromPartialJSON: accumulatedAssistantText
                    ), rewriteSoFar != lastEmittedRewriteText {
                        lastEmittedRewriteText = rewriteSoFar
                        continuation.yield(.partialRewrite(rewriteSoFar: rewriteSoFar))
                    }
                } else if eventType == "message_stop" {
                    // Stream is done. Fall through to the parse step
                    // below — leaving the loop early would skip events
                    // queued after this one (Anthropic occasionally
                    // emits `usage` events after message_stop).
                    continue
                }
            }

            _ = leftoverLineBuffer  // silence unused-write warning
            print("🧠 stream event-type counts: \(streamSeenEventTypeCounts)")

            // Stream finished. Parse the accumulated text as the
            // CoachResponse JSON. Models sometimes wrap the JSON in
            // ```json fences or prepend a short preamble despite the
            // system prompt — be tolerant of that by extracting the
            // first balanced { … } block.
            let extractedJSON = extractJSONObject(from: accumulatedAssistantText)
            print("🧠 stream raw assistant text (\(accumulatedAssistantText.count) chars): \(accumulatedAssistantText.prefix(500))")
            print("🧠 stream extracted JSON: \(extractedJSON.prefix(500))")

            // Strict parse first. Most responses are well-formed.
            if let jsonData = extractedJSON.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(CoachResponse.self, from: jsonData) {
                continuation.yield(.completed(decoded))
                continuation.finish()
                return
            }

            // Lenient parse fallback: response was likely truncated by
            // max_tokens. We rebuild a minimal valid JSON envelope from
            // whatever string fields we managed to extract from the
            // partial text. Better to show a partial nudge + rewrite
            // than fail silently.
            let recoveredCoachResponse = buildBestEffortCoachResponseFromTruncatedJSON(
                truncatedJSON: extractedJSON
            )
            if let recoveredCoachResponse {
                print("🧠 recovered partial response from truncated JSON.")
                continuation.yield(.completed(recoveredCoachResponse))
            } else {
                continuation.yield(.failed(.decode(
                    NSError(domain: "CoachAPIClient", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "could not recover any usable fields from stream"
                    ]),
                    extractedJSON
                )))
            }
        } catch {
            continuation.yield(.failed(.transport(error)))
        }
        continuation.finish()
    }
}

/// When the streamed JSON is truncated mid-field (e.g. max_tokens hit
/// inside the `checks` array), strict JSONDecoder fails. This best-effort
/// recovery yanks out `mode`, `nudge`, and `rewrite` directly with the
/// same partial-field extractor we use for the typewriter, then synthesizes
/// a minimal CoachResponse so the user at least sees the nudge + rewrite.
///
/// Returns nil if even `mode` or `nudge` couldn't be found — at that
/// point there's nothing useful to show.
fileprivate func buildBestEffortCoachResponseFromTruncatedJSON(
    truncatedJSON: String
) -> CoachResponse? {
    guard let recoveredMode = extractPartialStringField(named: "mode", fromPartialJSON: truncatedJSON),
          !recoveredMode.isEmpty,
          let recoveredNudge = extractPartialStringField(named: "nudge", fromPartialJSON: truncatedJSON),
          !recoveredNudge.isEmpty
    else {
        return nil
    }
    let recoveredRewrite = extractPartialStringField(named: "rewrite", fromPartialJSON: truncatedJSON)

    // Synthesize a JSON the decoder can actually parse, dropping the
    // truncated tail fields entirely.
    var synthesizedJSONObject: [String: Any] = [
        "mode": recoveredMode,
        "nudge": recoveredNudge,
    ]
    if let recoveredRewrite, !recoveredRewrite.isEmpty {
        synthesizedJSONObject["rewrite"] = recoveredRewrite
    } else {
        synthesizedJSONObject["rewrite"] = NSNull()
    }
    synthesizedJSONObject["checks"] = NSNull()
    synthesizedJSONObject["point"] = NSNull()
    synthesizedJSONObject["warnings"] = NSNull()

    guard let synthesizedData = try? JSONSerialization.data(withJSONObject: synthesizedJSONObject),
          let synthesizedResponse = try? JSONDecoder().decode(CoachResponse.self, from: synthesizedData)
    else {
        return nil
    }
    return synthesizedResponse
}

/// Pull the first balanced JSON object out of an assistant reply.
/// Tolerant of:
///   - leading/trailing whitespace
///   - markdown code fences like ```json ... ```
///   - a short prose preamble before the JSON
/// Returns the substring starting at the first `{` and ending at its
/// matching `}` (respecting string literals and escape sequences). If no
/// balanced object is found, returns the input unchanged so the caller's
/// JSONDecoder error message still includes the original.
fileprivate func extractJSONObject(from rawAssistantReply: String) -> String {
    // Quick path: stripped fences cover most cases.
    let strippedFences = rawAssistantReply
        .replacingOccurrences(of: "```json", with: "")
        .replacingOccurrences(of: "```", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard let openBraceIndex = strippedFences.firstIndex(of: "{") else {
        return strippedFences
    }

    // Walk forward keeping a brace-depth counter, respecting string
    // literals so a `}` inside a string doesn't close the object.
    var insideStringLiteral = false
    var escapeNextCharacter = false
    var braceDepth = 0
    var currentIndex = openBraceIndex
    while currentIndex < strippedFences.endIndex {
        let character = strippedFences[currentIndex]
        if escapeNextCharacter {
            escapeNextCharacter = false
        } else if insideStringLiteral {
            if character == "\\" {
                escapeNextCharacter = true
            } else if character == "\"" {
                insideStringLiteral = false
            }
        } else {
            switch character {
            case "\"":
                insideStringLiteral = true
            case "{":
                braceDepth += 1
            case "}":
                braceDepth -= 1
                if braceDepth == 0 {
                    let endIndex = strippedFences.index(after: currentIndex)
                    return String(strippedFences[openBraceIndex..<endIndex])
                }
            default:
                break
            }
        }
        currentIndex = strippedFences.index(after: currentIndex)
    }
    // Didn't find balanced close — return everything from the opening
    // brace so the decoder error message at least points at the body.
    return String(strippedFences[openBraceIndex...])
}

// MARK: - Partial JSON field extractor

/// Scans a possibly-incomplete JSON string for `"<fieldName>": "..."` and
/// returns the (possibly partial) value of that string field. Designed to
/// be called repeatedly as more characters arrive — it's tolerant of:
///   - missing closing quote (stream cut mid-value)
///   - missing closing brace
///   - extra whitespace
///   - escaped characters inside the value (\" \\ \n etc.)
///
/// Returns nil if the field's opening quote hasn't been emitted yet.
fileprivate func extractPartialStringField(
    named fieldName: String,
    fromPartialJSON partialJSON: String
) -> String? {
    // Find the field key. We allow whitespace around the colon.
    let searchPattern = "\"\(fieldName)\""
    guard let keyRange = partialJSON.range(of: searchPattern) else {
        return nil
    }
    // After the key, scan forward to find the first unescaped `"` that
    // opens the value.
    var scanIndex = keyRange.upperBound
    // Skip the colon and any whitespace.
    var sawColon = false
    while scanIndex < partialJSON.endIndex {
        let character = partialJSON[scanIndex]
        if character == ":" { sawColon = true }
        else if !character.isWhitespace && sawColon { break }
        scanIndex = partialJSON.index(after: scanIndex)
    }
    guard sawColon,
          scanIndex < partialJSON.endIndex,
          partialJSON[scanIndex] == "\""
    else {
        return nil
    }
    // scanIndex is the opening quote of the value. Walk forward,
    // collecting characters into the result. Stop at the matching
    // unescaped closing quote — or at end-of-input (still partial).
    var resultCharacters: [Character] = []
    var characterIndex = partialJSON.index(after: scanIndex)
    while characterIndex < partialJSON.endIndex {
        let character = partialJSON[characterIndex]
        if character == "\\" {
            // Handle simple escape sequences. We don't need to be
            // perfect because the final JSON is parsed again at the
            // end of the stream; this is just for the typewriter.
            let nextIndex = partialJSON.index(after: characterIndex)
            if nextIndex < partialJSON.endIndex {
                let escapeCharacter = partialJSON[nextIndex]
                switch escapeCharacter {
                case "n": resultCharacters.append("\n")
                case "t": resultCharacters.append("\t")
                case "r": resultCharacters.append("\r")
                case "\"": resultCharacters.append("\"")
                case "\\": resultCharacters.append("\\")
                case "/": resultCharacters.append("/")
                default: resultCharacters.append(escapeCharacter)
                }
                characterIndex = partialJSON.index(after: nextIndex)
                continue
            } else {
                // Trailing backslash — value is still streaming. Stop
                // here and return what we have.
                break
            }
        } else if character == "\"" {
            // End of string value.
            break
        } else {
            resultCharacters.append(character)
        }
        characterIndex = partialJSON.index(after: characterIndex)
    }
    return String(resultCharacters)
}
