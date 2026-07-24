import Foundation

public struct GrokUsageSnapshot: Sendable {
    public let billing: GrokBillingResponse?
    public let webBilling: GrokWebBillingSnapshot?
    public let credentials: GrokCredentials?
    public let localSummary: GrokLocalSessionSummary?
    public let cliVersion: String?
    public let diagnostic: String?
    public let updatedAt: Date

    public init(
        billing: GrokBillingResponse?,
        webBilling: GrokWebBillingSnapshot? = nil,
        credentials: GrokCredentials?,
        localSummary: GrokLocalSessionSummary?,
        cliVersion: String?,
        updatedAt: Date,
        diagnostic: String? = nil)
    {
        self.billing = billing
        self.webBilling = webBilling
        self.credentials = credentials
        self.localSummary = localSummary
        self.cliVersion = cliVersion
        self.diagnostic = diagnostic
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        // Primary window: credit usage (against included limit) from the CLI RPC,
        // falling back to the web billing RPC used by grok.com when the agent surface lacks billing.
        var primary: RateWindow?
        if let billing,
           let percent = billing.monthlyUsedPercent
        {
            primary = RateWindow(
                usedPercent: percent,
                windowMinutes: billing.billingPeriodMinutes,
                resetsAt: billing.billingPeriodEndDate,
                resetDescription: nil)
        } else if let webBilling,
                  let percent = webBilling.usedPercent
        {
            primary = RateWindow(
                usedPercent: percent,
                windowMinutes: nil,
                resetsAt: webBilling.resetsAt,
                resetDescription: nil)
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .grok,
            accountEmail: self.credentials?.email,
            accountOrganization: self.credentials?.teamId,
            loginMethod: self.credentials?.loginMethod)

        // Always surface local Grok Build session tokens when available so the
        // menu bar still tracks Grok even when remote billing is down / unsupported.
        let localCost = self.localSummary?.providerCostSnapshot(updatedAt: self.updatedAt)

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            providerCost: localCost,
            updatedAt: self.updatedAt,
            identity: identity,
            dataConfidence: primary != nil ? .percentOnly : (localCost != nil ? .estimated : .unknown))
    }

    /// Diagnostic string preferred for CLI / verbose consumers (remote + local).
    public var displayDiagnostic: String? {
        let remote = self.diagnostic?.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = self.localSummary?.hasActivity == true ? self.localSummary?.diagnosticLine : nil
        switch (remote?.isEmpty == false ? remote : nil, local) {
        case let (r?, l?): return "\(r) · \(l)"
        case let (r?, nil): return r
        case let (nil, l?): return l
        default: return nil
        }
    }
}

public struct GrokStatusProbe: Sendable {
    public static let teamUsageUnavailableMessage =
        "Grok team usage is unavailable from the current billing surface; identity is still available."

    public init() {}

    public static func detectVersion(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let binary = BinaryLocator.resolveGrokBinary(env: env) else { return nil }
        guard let output = ProviderVersionDetector.run(
            path: binary,
            args: ["--version"],
            environment: env,
            mergeStandardError: true)
        else { return nil }
        // Output is like "grok 0.1.210 (8b63e9068c)" — strip the leading "grok " so
        // callers can prefix the CLI name themselves without duplicating it.
        let withoutPrefix = output.replacingOccurrences(
            of: #"^grok\s+"#,
            with: "",
            options: [.regularExpression])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return withoutPrefix.isEmpty ? nil : withoutPrefix
    }

    public func fetch(env: [String: String] = ProcessInfo.processInfo.environment) async throws -> GrokUsageSnapshot {
        // Credentials are optional: we still show identity-less state if the user
        // hasn't logged in, with a clear hint via the RPC error.
        let credentials = try? GrokCredentialsStore.load(env: env)

        var billing: GrokBillingResponse?
        var rpcError: Error?
        var billingAttempted = false
        do {
            let client = try GrokRPCClient(environment: env)
            defer { client.shutdown() }
            try await client.initialize()
            billingAttempted = true
            billing = try await client.fetchBilling()
        } catch {
            rpcError = error
        }

        // Local fallback summary always succeeds (empty if no sessions yet).
        let localSummary = GrokLocalSessionScanner.summarize(env: env)
        let cliVersion = Self.detectVersion(env: env)

        // Team principals: identity-only when the billing method is missing (no
        // supported team usage surface yet). Personal principals still fall through
        // to the web strategy in auto mode; local-session fallback is a separate
        // strategy so remote billing still gets a chance first.
        if billing == nil,
           let credentials,
           Self.shouldUseIdentityOnlyFallback(
               credentials: credentials,
               billingAttempted: billingAttempted,
               error: rpcError)
        {
            return Self.identityOnlySnapshot(
                credentials: credentials,
                localSummary: localSummary,
                cliVersion: cliVersion)
        }

        if billing == nil {
            throw rpcError ?? GrokRPCError.notAuthenticated
        }

        return GrokUsageSnapshot(
            billing: billing,
            webBilling: nil,
            credentials: Self.credentialsForSnapshot(
                credentials: credentials,
                billing: billing,
                webBilling: nil),
            localSummary: localSummary,
            cliVersion: cliVersion,
            updatedAt: Date())
    }

    /// Offline snapshot from `~/.grok/auth.json` + local session signals.
    /// Used as the last-resort strategy when CLI billing RPC and web billing both fail.
    public static func localFallbackSnapshot(
        env: [String: String] = ProcessInfo.processInfo.environment) throws -> GrokUsageSnapshot
    {
        let credentials = try? GrokCredentialsStore.load(env: env)
        let localSummary = GrokLocalSessionScanner.summarize(env: env)
        let cliVersion = Self.detectVersion(env: env)

        guard localSummary.hasActivity || credentials != nil else {
            throw GrokRPCError.notAuthenticated
        }

        // Keep identity even when the access token is expired — local session
        // totals still track "your" Grok usage from ~/.grok/sessions.
        return GrokUsageSnapshot(
            billing: nil,
            webBilling: nil,
            credentials: credentials,
            localSummary: localSummary,
            cliVersion: cliVersion,
            updatedAt: Date(),
            diagnostic: localSummary.hasActivity
                ? nil
                : "No remote Grok billing available; run `grok login` or sign in at grok.com.")
    }

    static func identityOnlySnapshot(
        credentials: GrokCredentials,
        localSummary: GrokLocalSessionSummary?,
        cliVersion: String?,
        updatedAt: Date = .init()) -> GrokUsageSnapshot
    {
        GrokUsageSnapshot(
            billing: nil,
            webBilling: nil,
            credentials: credentials,
            localSummary: localSummary,
            cliVersion: cliVersion,
            updatedAt: updatedAt,
            diagnostic: GrokStatusProbe.teamUsageUnavailableMessage)
    }

    static func isBillingMethodUnavailable(_ error: Error?) -> Bool {
        guard let error,
              case let GrokRPCError.requestFailed(message) = error
        else {
            return false
        }
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "method not found" || normalized.hasPrefix("method not found:")
    }

    static func shouldUseIdentityOnlyFallback(
        credentials: GrokCredentials?,
        billingAttempted: Bool,
        error: Error?) -> Bool
    {
        guard billingAttempted,
              let credentials,
              !credentials.isExpired,
              credentials.isTeamPrincipal
        else {
            return false
        }
        return Self.isBillingMethodUnavailable(error)
    }

    static func credentialsForSnapshot(
        credentials: GrokCredentials?,
        billing: GrokBillingResponse?,
        webBilling: GrokWebBillingSnapshot? = nil) -> GrokCredentials?
    {
        // If remote usage succeeded, xAI accepted auth and the local
        // identity is still useful even when the persisted expires_at is stale.
        if billing != nil || webBilling != nil { return credentials }
        return credentials.flatMap { $0.isExpired ? nil : $0 }
    }

    static func shouldSurfaceRemoteAuthError(_ error: Error?) -> Bool {
        guard let error = error as? GrokWebBillingError else { return false }
        switch error {
        case let .requestFailed(status, _):
            return status == 401 || status == 403
        case let .rpcFailed(status, _):
            return status == 16
        case .missingCredentials, .emptyResponse, .invalidResponse, .teamUsageUnsupported, .parseFailed:
            return false
        }
    }
}
