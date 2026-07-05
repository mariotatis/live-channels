//
//  RootView.swift
//  Channels
//
//  Boot gate: silent activation → root tabs. Never shows a login screen
//  (docs 02, 13). A neutral error screen is shown only if activation fails.
//

import SwiftUI

struct RootView: View {
    @State private var activation = ActivationService.shared

    var body: some View {
        Group {
            switch activation.state {
            case .idle, .activating:
                SplashView()
            case .active:
                RootTabView()
                    .transition(.opacity)
            case .failed(let message):
                ServiceUnavailableView(message: message) {
                    Task { await activation.activate() }
                }
            }
        }
        .animation(.easeInOut, value: activation.state)
        .task { await activation.bootstrap() }
        .preferredColorScheme(.dark)
    }
}

struct SplashView: View {
    @State private var pulse = false
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(Theme.brandGradient)
                    .scaleEffect(pulse ? 1.08 : 0.92)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                Text(AppConfig.appName)
                    .font(.largeTitle.bold())
                    .foregroundStyle(Theme.brandGradient)
                ProgressView().tint(Theme.accent)
            }
        }
        .onAppear { pulse = true }
    }
}

struct ServiceUnavailableView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.icloud")
                    .font(.system(size: 56)).foregroundStyle(Theme.textSecondary)
                Text("Service Unavailable").font(.title2.bold()).foregroundStyle(Theme.textPrimary)
                Text(message).font(.callout).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
                Button("Retry", action: retry)
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
        }
    }
}
