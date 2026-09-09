import InfinitusCore

/// One place for how a login need reads on the phone (#367): AWS logins
/// name a profile, gcloud ones an account (or the application default
/// credentials); everything else is the provider's own `loginLabel`.
extension AwsLogin.Item {
    /// "profile papaya" / "account loc@…" / "application default credentials".
    var subjectLabel: String { AwsLogin.subjectLabel(provider: providerOrAws, profile: profile) }
    /// "Needs AWS login" / "Needs gcloud login".
    var needLabel: String { "Needs \(providerOrAws.loginLabel)" }
}

extension AwsLogin {
    static func subjectLabel(provider: Provider, profile: String) -> String {
        switch provider {
        case .aws: return "profile \(profile)"
        case .gcloud: return profile == GcloudLogin.adcProfile ? GcloudLogin.label(profile: profile) : "account \(profile)"
        }
    }
}
