//
//  PinViews.swift
//  Channels
//
//  Reusable 6-digit PIN UI: a keypad (PinPadView), a verify screen
//  (PinEntryView), and a set/confirm screen (PinSetupView). Key presses give a
//  light haptic tick; a rejected code triggers an error haptic + a "no" shake.
//

import SwiftUI
import UIKit

/// Horizontal "no" shake for a wrong PIN.
private struct ShakeEffect: GeometryEffect {
    var travel: CGFloat = 9
    var shakes: CGFloat = 3
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(animatableData * .pi * shakes), y: 0))
    }
}

/// PIN keypad key: fills a rounded rectangle that lightens clearly while pressed
/// so the tapped key is obvious.
private struct PinKeyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: 70)
            .background(configuration.isPressed
                        ? Color(red: 0.34, green: 0.34, blue: 0.40)
                        : Theme.surface,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Low-level 6-digit PIN pad. `onCode` returns whether the code was accepted;
/// if it returns false the pad shakes + plays an error haptic, then clears.
struct PinPadView: View {
    let title: String
    var subtitle: String? = nil
    var errorMessage: String? = nil
    let onCode: (String) -> Bool

    @State private var code = ""
    @State private var shake: CGFloat = 0
    private let maxDigits = 6
    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "del"]

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                Text(title).font(.title2.bold()).foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            dots
            Text(errorMessage ?? " ")
                .font(.footnote).foregroundStyle(Theme.accent)
            pad
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(ShakeEffect(animatableData: shake))
        .mooveesBackground()
    }

    private var dots: some View {
        HStack(spacing: 16) {
            ForEach(0..<maxDigits, id: \.self) { i in
                Circle()
                    .strokeBorder(Theme.textTertiary, lineWidth: 1.5)
                    .background(Circle().fill(i < code.count ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.clear)))
                    .frame(width: 18, height: 18)
            }
        }
    }

    private var pad: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 18) {
            ForEach(keys, id: \.self) { key in
                if key.isEmpty {
                    Color.clear.frame(height: 70)
                } else {
                    Button { tap(key) } label: {
                        Group {
                            if key == "del" {
                                Image(systemName: "delete.left").font(.title2)
                            } else {
                                Text(key).font(.title.weight(.medium))
                            }
                        }
                        .foregroundStyle(Theme.textPrimary)
                    }
                    .buttonStyle(PinKeyButtonStyle())
                }
            }
        }
        .padding(.horizontal, 28)
    }

    private func tap(_ key: String) {
        if key == "del" {
            if !code.isEmpty { code.removeLast(); tick() }
            return
        }
        guard code.count < maxDigits else { return }
        tick()
        code.append(key)
        guard code.count == maxDigits else { return }
        let entered = code
        if onCode(entered) {
            code = ""
        } else {
            reject()
        }
    }

    private func tick() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func reject() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        withAnimation(.linear(duration: 0.4)) { shake += 1 }
        // Keep the filled dots visible during the shake, then clear.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { code = "" }
    }
}

/// Verifies an existing PIN. Calls `onSuccess` when the correct PIN is entered.
struct PinEntryView: View {
    let title: String
    var subtitle: String? = "Enter your parental PIN"
    let onSuccess: () -> Void

    @State private var error: String?

    var body: some View {
        PinPadView(title: title, subtitle: subtitle, errorMessage: error) { code in
            if ParentalControl.shared.verify(code) {
                error = nil
                onSuccess()
                return true
            } else {
                error = "Incorrect PIN. Try again."
                return false
            }
        }
    }
}

/// Two-step set/confirm of a new PIN. Saves it and calls `onSaved` on success.
struct PinSetupView: View {
    @Environment(\.dismiss) private var dismiss
    var onSaved: () -> Void = {}

    @State private var firstPin: String?
    @State private var error: String?

    var body: some View {
        Group {
            if let firstPin {
                PinPadView(title: "Confirm PIN", subtitle: "Re-enter the 6-digit PIN", errorMessage: error) { code in
                    if code == firstPin {
                        ParentalControl.shared.setPin(code)
                        onSaved()
                        dismiss()
                        return true
                    } else {
                        error = "PINs don't match. Start over."
                        self.firstPin = nil
                        return false
                    }
                }
            } else {
                PinPadView(title: "Set a PIN", subtitle: "Choose a 6-digit PIN") { code in
                    error = nil
                    firstPin = code
                    return true
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
    }
}
