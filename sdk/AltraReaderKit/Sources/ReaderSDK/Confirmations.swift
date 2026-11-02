import Foundation
import ReaderProtocol

/// Destructive or irreversible operations (write, lock, kill, firmware update,
/// permanent config save) must never run from data alone — the caller has to
/// construct one of these explicitly, which forces a UI (or CLI) to show a real
/// confirmation step rather than being able to "accidentally" chain a write.
///
/// This does not replace UI-level confirmation dialogs — it's a second, structural
/// gate: even a scripting bug can't fire a write without deliberately building one
/// of these values with the target and data spelled out.
public struct WriteConfirmation: Sendable {
    public let targetEPC: String
    public let bank: MemoryBank
    public let startAddress: Int
    public let dataHex: String
    public let userAcknowledged: Bool

    public init(targetEPC: String, bank: MemoryBank, startAddress: Int, dataHex: String, userAcknowledged: Bool) {
        self.targetEPC = targetEPC
        self.bank = bank
        self.startAddress = startAddress
        self.dataHex = dataHex
        self.userAcknowledged = userAcknowledged
    }
}

public enum LockType: String, Sendable, Hashable { case unlock, temporaryLock, permanentLock }

public struct LockConfirmation: Sendable {
    public let targetEPC: String
    public let bank: MemoryBank
    public let lockType: LockType
    public let accessPassword: String
    public let userAcknowledged: Bool
    /// Permanent locks cannot be undone — the reference manual is explicit about
    /// this ("After being locked, the lock cannot be unlocked" for permanent locks).
    public let understandsIrreversibility: Bool

    public init(targetEPC: String, bank: MemoryBank, lockType: LockType, accessPassword: String,
                userAcknowledged: Bool, understandsIrreversibility: Bool) {
        self.targetEPC = targetEPC
        self.bank = bank
        self.lockType = lockType
        self.accessPassword = accessPassword
        self.userAcknowledged = userAcknowledged
        self.understandsIrreversibility = understandsIrreversibility
    }
}

public struct KillConfirmation: Sendable {
    public let targetEPC: String
    public let killPassword: String
    public let userAcknowledged: Bool
    public let understandsIrreversibility: Bool

    public init(targetEPC: String, killPassword: String, userAcknowledged: Bool, understandsIrreversibility: Bool) {
        self.targetEPC = targetEPC
        self.killPassword = killPassword
        self.userAcknowledged = userAcknowledged
        self.understandsIrreversibility = understandsIrreversibility
    }
}
