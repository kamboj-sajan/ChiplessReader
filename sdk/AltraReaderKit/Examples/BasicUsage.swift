// Examples/BasicUsage.swift
//
// Not part of any build target — a copy-pasteable reference for embedding
// ReaderSDK in your own app. See Sources/ReaderCLI/main.swift for a fully
// working, buildable example.

import Foundation
import ReaderTransport
import ReaderSDK

func exampleBasicInventory() async throws {
    let client = ReaderClient(descriptor: .mock())
    try await client.connect()

    let listener = Task {
        for await event in client.events {
            if case .tagRead(let read) = event {
                print("\(read.epc)  ant=\(read.antenna)  rssi=\(read.rssi)")
            }
        }
    }

    try await client.startInventory(antennas: [1])
    try await Task.sleep(nanoseconds: 5_000_000_000)
    try await client.stopInventory()
    listener.cancel()

    await client.disconnect()
}

func exampleSafeWrite() async throws {
    let client = ReaderClient(descriptor: .mock())
    try await client.connect()

    // Deliberately verbose — see Documentation/API.md for why write/lock/kill
    // require an explicit, fully-acknowledged confirmation value.
    let confirmation = WriteConfirmation(
        targetEPC: "E2806890000005005BE02ED11",
        bank: .user,
        startAddress: 0,
        dataHex: "CAFEBABE",
        userAcknowledged: true // an app UI should set this only after a real user confirmation dialog
    )
    try await client.writeMemory(confirmation)
    await client.disconnect()
}
