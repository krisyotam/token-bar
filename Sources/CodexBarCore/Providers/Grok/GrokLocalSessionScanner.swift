import Foundation

/// Aggregated stats from local `~/.grok/sessions/**/signals.json` files.
/// Used as a local fallback view when the JSON-RPC / web billing call is unavailable,
/// and as always-on local token cost context when remote usage is available.
public struct GrokLocalSessionSummary: Sendable {
    public let sessionCount: Int
    /// Tokens over the full lookback window (default 30 days).
    public let totalTokens: Int
    /// Tokens from sessions modified in the last 24 hours (local calendar day window).
    public let todayTokens: Int
    /// Tokens from sessions modified in the last 7 days.
    public let weekTokens: Int
    public let lastSessionAt: Date?
    public let primaryModel: String?
    public let models: [String]

    public init(
        sessionCount: Int,
        totalTokens: Int,
        todayTokens: Int = 0,
        weekTokens: Int = 0,
        lastSessionAt: Date?,
        primaryModel: String?,
        models: [String])
    {
        self.sessionCount = sessionCount
        self.totalTokens = totalTokens
        self.todayTokens = todayTokens
        self.weekTokens = weekTokens
        self.lastSessionAt = lastSessionAt
        self.primaryModel = primaryModel
        self.models = models
    }

    public var hasActivity: Bool {
        self.sessionCount > 0 || self.totalTokens > 0
    }

    /// Human-readable diagnostic line for menu cards / CLI verbose mode.
    public var diagnosticLine: String {
        var parts: [String] = []
        if self.todayTokens > 0 {
            parts.append("today \(Self.formatTokens(self.todayTokens))")
        }
        if self.weekTokens > 0 {
            parts.append("7d \(Self.formatTokens(self.weekTokens))")
        }
        if self.totalTokens > 0, self.totalTokens != self.weekTokens {
            parts.append("30d \(Self.formatTokens(self.totalTokens))")
        }
        if self.sessionCount > 0 {
            parts.append("\(self.sessionCount) session\(self.sessionCount == 1 ? "" : "s")")
        }
        if let model = self.primaryModel?.nilIfEmpty {
            parts.append(model)
        }
        guard !parts.isEmpty else { return "No local Grok sessions yet." }
        return "Local: " + parts.joined(separator: " · ")
    }

    public func providerCostSnapshot(updatedAt: Date = .init()) -> ProviderCostSnapshot? {
        // Prefer the most recent non-zero window so the cost chip stays meaningful.
        let used: Double
        let period: String
        if self.todayTokens > 0 {
            used = Double(self.todayTokens)
            period = "Local today"
        } else if self.weekTokens > 0 {
            used = Double(self.weekTokens)
            period = "Local 7d"
        } else if self.totalTokens > 0 {
            used = Double(self.totalTokens)
            period = "Local 30d"
        } else {
            return nil
        }
        return ProviderCostSnapshot(
            used: used,
            limit: 0,
            currencyCode: "tok",
            period: period,
            resetsAt: nil,
            updatedAt: updatedAt)
    }

    private static func formatTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

public enum GrokLocalSessionScanner {
    public static let defaultLookbackDays = 30

    /// Walk `~/.grok/sessions/<encoded_cwd>/<session_id>/signals.json` and aggregate stats.
    public static func summarize(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        lookbackDays: Int = defaultLookbackDays,
        now: Date = .init()) -> GrokLocalSessionSummary
    {
        let root = GrokCredentialsStore.grokHomeURL(env: env, fileManager: fileManager)
            .appendingPathComponent("sessions", isDirectory: true)
        guard let rootEnum = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])
        else {
            return GrokLocalSessionSummary(
                sessionCount: 0,
                totalTokens: 0,
                todayTokens: 0,
                weekTokens: 0,
                lastSessionAt: nil,
                primaryModel: nil,
                models: [])
        }

        let calendar = Calendar.current
        let lookbackCutoff = calendar.date(byAdding: .day, value: -lookbackDays, to: now) ?? now
        let todayCutoff = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let weekCutoff = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        var sessionCount = 0
        var totalTokens = 0
        var todayTokens = 0
        var weekTokens = 0
        var lastSessionAt: Date?
        var modelCounts: [String: Int] = [:]

        while let url = rootEnum.nextObject() as? URL {
            guard url.lastPathComponent == "signals.json" else { continue }
            let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let mtime = attrs?.contentModificationDate ?? Date.distantPast
            guard mtime >= lookbackCutoff else { continue }

            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            sessionCount += 1
            // Prefer cumulative pre-compaction when present; otherwise fall back to
            // the live context window size so short sessions still count.
            let beforeCompaction = (json["totalTokensBeforeCompaction"] as? Int) ?? 0
            let contextUsed = (json["contextTokensUsed"] as? Int) ?? 0
            let sessionTokens = beforeCompaction > 0 ? beforeCompaction : contextUsed
            totalTokens += sessionTokens
            if mtime >= weekCutoff {
                weekTokens += sessionTokens
            }
            if mtime >= todayCutoff {
                todayTokens += sessionTokens
            }

            if mtime > (lastSessionAt ?? Date.distantPast) {
                lastSessionAt = mtime
            }

            if let primary = (json["primaryModelId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !primary.isEmpty
            {
                modelCounts[primary, default: 0] += 1
            }
            if let models = json["modelsUsed"] as? [String] {
                for model in models {
                    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        modelCounts[trimmed, default: 0] += 1
                    }
                }
            }
        }

        let sortedModels = modelCounts.sorted { $0.value > $1.value }.map(\.key)
        return GrokLocalSessionSummary(
            sessionCount: sessionCount,
            totalTokens: totalTokens,
            todayTokens: todayTokens,
            weekTokens: weekTokens,
            lastSessionAt: lastSessionAt,
            primaryModel: sortedModels.first,
            models: sortedModels)
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
