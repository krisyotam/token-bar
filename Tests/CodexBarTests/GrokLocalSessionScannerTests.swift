import Foundation
import Testing
@testable import CodexBarCore

struct GrokLocalSessionScannerTests {
    @Test
    func `summary formats diagnostic and cost chip from token buckets`() {
        let summary = GrokLocalSessionSummary(
            sessionCount: 3,
            totalTokens: 2_500_000,
            todayTokens: 120_000,
            weekTokens: 900_000,
            lastSessionAt: Date(timeIntervalSince1970: 1_800_000_000),
            primaryModel: "grok-4.5",
            models: ["grok-4.5", "grok-composer-2.5-fast"])

        #expect(summary.hasActivity)
        #expect(summary.diagnosticLine.contains("today"))
        #expect(summary.diagnosticLine.contains("7d"))
        #expect(summary.diagnosticLine.contains("grok-4.5"))

        let cost = try #require(summary.providerCostSnapshot(
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(cost.used == 120_000)
        #expect(cost.currencyCode == "tok")
        #expect(cost.period == "Local today")
    }

    @Test
    func `local-only usage snapshot carries cost without primary window`() {
        let summary = GrokLocalSessionSummary(
            sessionCount: 1,
            totalTokens: 50_000,
            todayTokens: 0,
            weekTokens: 50_000,
            lastSessionAt: Date(timeIntervalSince1970: 1_800_000_000),
            primaryModel: "grok-4.5",
            models: ["grok-4.5"])
        let credentials = GrokCredentials(
            accessToken: "tok",
            refreshToken: nil,
            scope: "https://auth.x.ai::client",
            authMode: "oidc",
            userId: "u",
            email: "kris@example.com",
            firstName: "Kris",
            lastName: nil,
            teamId: nil,
            principalType: "User",
            oidcIssuer: "https://auth.x.ai",
            oidcClientId: "client",
            expiresAt: nil,
            createTime: nil)
        let snapshot = GrokUsageSnapshot(
            billing: nil,
            webBilling: nil,
            credentials: credentials,
            localSummary: summary,
            cliVersion: "0.1.220",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.providerCost?.used == 50_000)
        #expect(usage.providerCost?.currencyCode == "tok")
        #expect(usage.providerCost?.period == "Local 7d")
        #expect(usage.accountEmail(for: .grok) == "kris@example.com")
        #expect(usage.dataConfidence == .estimated)
        #expect(snapshot.displayDiagnostic?.contains("Local:") == true)
    }

    @Test
    func `defaultEnabled is true for Grok on this fork`() {
        #expect(GrokProviderDescriptor.descriptor.metadata.defaultEnabled == true)
    }
}
