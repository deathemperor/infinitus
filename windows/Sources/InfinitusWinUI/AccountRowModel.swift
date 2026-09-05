import Foundation
import InfinitusCore

/// Model for row presentation and capability gating in the Accounts pane.
public struct AccountRowModel: Equatable, Sendable {
    public let engineID: String
    public let provider: Provider
    public let number: Int
    public let name: String
    public let email: String
    public let plan: String
    public let active: Bool
    public let held: Bool
    public let usageStatus: String
    public let preferred: Bool?

    // Affordance gates
    public let canSwitch: Bool
    public let canHold: Bool
    public let canRename: Bool
    public let canRemove: Bool
    public let canPrefer: Bool
    public let canReorder: Bool
    public let canRelogin: Bool

    public init(
        account: Account,
        activeNumber: Int?,
        engineID: String,
        provider: Provider,
        capabilities: EngineCapabilities
    ) {
        self.engineID = engineID
        self.provider = provider
        self.number = account.number
        self.name = account.alias?.isEmpty == false ? account.alias! : String(account.email.prefix(while: { $0 != "@" }))
        self.email = account.email
        self.plan = account.plan ?? ""
        let isActive = account.active || (activeNumber != nil && account.number == activeNumber)
        self.active = isActive
        self.held = account.disabled ?? false
        self.usageStatus = account.usageStatus
        self.preferred = account.preferred

        self.canSwitch = capabilities.contains(.switch) && !isActive
        self.canHold = capabilities.contains(.hold)
        self.canRename = capabilities.contains(.rename)
        self.canRemove = capabilities.contains(.remove)
        self.canPrefer = capabilities.contains(.prefer) && account.preferred != nil
        self.canReorder = capabilities.contains(.reorder)
        self.canRelogin = (engineID == "cswap")
    }
}
