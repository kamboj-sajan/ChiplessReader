import SwiftUI
import ReaderProtocol
import ReaderSDK

struct TagAccessView: View {
    @EnvironmentObject var model: AppModel

    @State private var targetEPC = ""
    @State private var bank: MemoryBank = .user
    @State private var startAddress = 0
    @State private var wordCount = 4
    @State private var accessPassword = ""
    @State private var writeDataHex = ""
    @State private var readResult = ""

    @State private var showWriteConfirm = false
    @State private var showLockConfirm = false
    @State private var showKillConfirm = false
    @State private var lockType: LockType = .temporaryLock
    @State private var killPassword = ""

    var body: some View {
        Form {
            Section("Target") {
                TextField("EPC", text: $targetEPC, prompt: Text("e.g. E2806890...")).font(.system(.body, design: .monospaced))
                Picker("Bank", selection: $bank) {
                    ForEach(MemoryBank.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Stepper("Start Address: \(startAddress)", value: $startAddress, in: 0...255)
                Stepper("Word Count: \(wordCount)", value: $wordCount, in: 1...32)
                SecureField("Access Password (optional)", text: $accessPassword)
            }

            Section("Read") {
                Button("Read") { Task { await performRead() } }
                    .disabled(!model.isConnected || targetEPC.isEmpty)
                if !readResult.isEmpty {
                    Text(readResult).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
            }

            Section("Write") {
                TextField("Data (hex)", text: $writeDataHex).font(.system(.body, design: .monospaced))
                Button("Write…") { showWriteConfirm = true }
                    .disabled(!model.isConnected || targetEPC.isEmpty || writeDataHex.isEmpty)
                    .foregroundStyle(.red)
            }

            Section("Lock") {
                Picker("Lock Type", selection: $lockType) {
                    Text("Unlock").tag(LockType.unlock)
                    Text("Temporary Lock").tag(LockType.temporaryLock)
                    Text("Permanent Lock").tag(LockType.permanentLock)
                }
                Button("Lock…") { showLockConfirm = true }
                    .disabled(!model.isConnected || targetEPC.isEmpty)
                    .foregroundStyle(.red)
            }

            Section("Destroy Tag") {
                SecureField("Kill Password", text: $killPassword)
                Button("Destroy Tag…") { showKillConfirm = true }
                    .disabled(!model.isConnected || targetEPC.isEmpty || killPassword.isEmpty)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .padding()
        .confirmationDialog("Write tag memory?", isPresented: $showWriteConfirm, titleVisibility: .visible) {
            Button("Write \(writeDataHex) to \(bank.rawValue)@\(startAddress) on \(targetEPC)", role: .destructive) {
                Task {
                    let confirmation = WriteConfirmation(targetEPC: targetEPC, bank: bank, startAddress: startAddress,
                                                            dataHex: writeDataHex, userAcknowledged: true)
                    await model.performWrite(confirmation)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This sends a write command to the tag's \(bank.rawValue) bank. This cannot be undone if the bank is locked afterward.")
        }
        .confirmationDialog("Lock tag?", isPresented: $showLockConfirm, titleVisibility: .visible) {
            Button("Apply \(lockType.rawValue) to \(targetEPC)", role: .destructive) {
                Task {
                    let confirmation = LockConfirmation(targetEPC: targetEPC, bank: bank, lockType: lockType,
                                                          accessPassword: accessPassword, userAcknowledged: true,
                                                          understandsIrreversibility: true)
                    await model.performLock(confirmation)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(lockType == .permanentLock
                 ? "Permanent locks CANNOT be undone. This matches the reader's own documented behavior."
                 : "Temporary locks can be reversed with the correct access password.")
        }
        .confirmationDialog("Destroy this tag permanently?", isPresented: $showKillConfirm, titleVisibility: .visible) {
            Button("Permanently destroy \(targetEPC)", role: .destructive) {
                Task {
                    let confirmation = KillConfirmation(targetEPC: targetEPC, killPassword: killPassword,
                                                          userAcknowledged: true, understandsIrreversibility: true)
                    await model.performKill(confirmation)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently and irreversibly disables the tag. It can never be used again.")
        }
    }

    private func performRead() async {
        readResult = "Reading…"
        do {
            readResult = try await model.readTagMemory(
                epc: targetEPC, bank: bank, startAddress: startAddress,
                wordCount: wordCount, accessPassword: accessPassword.isEmpty ? nil : accessPassword)
        } catch {
            readResult = "Error: \(error)"
        }
    }
}
