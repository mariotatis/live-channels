//
//  ParentalControlView.swift
//  Channels
//
//  Parental-control settings: a master on/off toggle and PIN management.
//  Turning the control ON requires a PIN (set it if none exists); turning it
//  OFF requires entering the PIN.
//

import SwiftUI

struct ParentalControlView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var parental = ParentalControl.shared

    @State private var setupToEnable = false
    @State private var changePin = false
    @State private var verifyToDisable = false
    @State private var changePinVerified = false

    var body: some View {
        List {
            Section {
                Toggle("Parental Control", isOn: toggleBinding)
            } footer: {
                Text("When on, opening the 18+ category requires your PIN.")
            }

            Section {
                Button { changePin = true } label: {
                    HStack {
                        Label("Pin code", systemImage: "key.fill")
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(parental.hasPin ? "Change" : "Set")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .clearListBackground()
        .mooveesBackground()
        .navigationTitle("Parental Control")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .sheet(isPresented: $setupToEnable) {
            NavContainer {
                PinSetupView(onSaved: { parental.enable() })
                    .navigationTitle("Set PIN").navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $changePin, onDismiss: { changePinVerified = false }) {
            NavContainer {
                if parental.hasPin && !changePinVerified {
                    // Changing an existing PIN requires the current PIN first.
                    PinEntryView(title: "Enter Current PIN",
                                 subtitle: "Verify your PIN to change it") {
                        changePinVerified = true
                    }
                    .navigationTitle("Change PIN").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { changePin = false } }
                    }
                } else {
                    PinSetupView()
                        .navigationTitle(parental.hasPin ? "Change PIN" : "Set PIN")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .sheet(isPresented: $verifyToDisable) {
            NavContainer {
                PinEntryView(title: "Turn Off Parental Control",
                             subtitle: "Enter your PIN to turn it off") {
                    parental.disable()
                    verifyToDisable = false
                }
                .navigationTitle("Enter PIN").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { verifyToDisable = false } }
                }
            }
        }
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { parental.isEnabled },
            set: { turnOn in
                if turnOn {
                    if parental.hasPin { parental.enable() } else { setupToEnable = true }
                } else {
                    verifyToDisable = true
                }
            }
        )
    }
}
