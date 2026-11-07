import GamEngine
import SwiftUI

/// One phone or tablet, in words, so VoiceOver reads it whole: Incident's check and a person's Security tab say it alike.
struct MobileDeviceRow: View {
    let device: Compromised.MobileDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(device.words).fontWeight(.semibold)
            Text("Last synced " + (device.lastSynced?.formatted(date: .abbreviated, time: .shortened) ?? device.lastSync)
                 + (device.firstSync.isEmpty ? "" : " · first "
                    + (device.firstSynced?.formatted(date: .abbreviated, time: .shortened) ?? device.firstSync))
                 + (device.status.isEmpty ? "" : " · \(device.status)"))
                .font(.callout).foregroundStyle(.secondary)
            if device.reportsCompromise {
                Label("Reports it's rooted or jailbroken", systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One computer, in words: Incident's check and a person's Security tab say it alike.
struct ComputerRow: View {
    let computer: Compromised.Computer

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(computer.words).fontWeight(.semibold)
            Text("Last synced " + (computer.lastSynced?.formatted(date: .abbreviated, time: .shortened) ?? computer.lastSync)
                 + (computer.firstSync.isEmpty ? "" : " · first signed in "
                    + (computer.firstSynced?.formatted(date: .abbreviated, time: .shortened) ?? computer.firstSync))
                 + (computer.ownership.isEmpty ? "" : " · \(computer.ownership)")
                 + (computer.state.isEmpty ? "" : " · \(computer.state)")
                 + (computer.serialNumber.isEmpty ? "" : " · serial \(computer.serialNumber)"))
                .font(.callout).foregroundStyle(.secondary)
            if computer.looksVirtual {
                Label("A virtual machine, as a remote attacker's often is", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }
            if computer.reportsCompromise {
                Label("Reports it's compromised", systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
