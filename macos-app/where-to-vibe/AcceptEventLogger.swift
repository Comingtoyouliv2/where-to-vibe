//
//  AcceptEventLogger.swift
//  where-to-vibe
//
//  Records each accepted suggestion to the server event log (Cloudflare D1 via
//  the Worker's /events route): what the user originally wrote -> the advice
//  they accepted, plus light context. Lets us analyze which advice users
//  actually find useful.
//
//  Privacy: anonymous. We send a random per-install device id (no account, no
//  name, no email). The prompt text itself is user content — fine for a small
//  consenting prototype (~10 users). Best-effort and fire-and-forget: any
//  failure is swallowed and never blocks or delays the Tab-accept.
//

import Foundation

enum AcceptEventLogger {
    private static let deviceIdentifierDefaultsKey = "PromptCoach.anonymousDeviceID"

    /// A stable, random identifier for this install. Generated once and kept in
    /// UserDefaults so events from the same user can be grouped without any PII.
    private static var anonymousDeviceIdentifier: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: deviceIdentifierDefaultsKey) {
            return existing
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: deviceIdentifierDefaultsKey)
        return generated
    }

    /// The Worker's /events endpoint, derived from the configured WorkerBaseURL.
    /// nil (logging disabled) when no worker is configured.
    private static var eventsEndpoint: URL? {
        guard let workerBaseURL = AppBundleConfiguration.stringValue(forKey: "WorkerBaseURL") else {
            return nil
        }
        let trimmedBase = workerBaseURL.hasSuffix("/") ? String(workerBaseURL.dropLast()) : workerBaseURL
        return URL(string: trimmedBase + "/events")
    }

    /// Sends one accepted-advice event. Returns immediately; the network call
    /// runs detached and its result is ignored.
    static func logAccepted(
        originalInput: String,
        acceptedAdvice: String,
        reason: String?,
        userLevel: String,
        stage: String,
        language: String,
        appName: String
    ) {
        guard let endpoint = eventsEndpoint else { return }

        var payload: [String: Any] = [
            "deviceId": anonymousDeviceIdentifier,
            "originalInput": originalInput,
            "acceptedAdvice": acceptedAdvice,
            "userLevel": userLevel,
            "stage": stage,
            "language": language,
            "appName": appName
        ]
        if let reason, !reason.isEmpty {
            payload["reason"] = reason
        }

        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // If the Worker is configured with a shared token, send it so the event
        // route accepts the request. Harmless (and ignored) when unset.
        if let sharedToken = AppBundleConfiguration.stringValue(forKey: "OpenAIProxyToken") {
            request.setValue(sharedToken, forHTTPHeaderField: "X-App-Token")
        }
        request.httpBody = httpBody

        // Fire-and-forget: don't await, don't surface errors.
        URLSession.shared.dataTask(with: request).resume()
    }
}
