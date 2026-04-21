import SwiftUI
import KatafractStyle

/// Splash shown on cold launch, before biometric lock prompt or file list.
/// "Hairline seal expands" — a gold hairline circle grows from 40pt to 120pt
/// while the sapphire shield fades in inside it; at the climax, the lock
/// glyph on the shield briefly rotates -15° and snaps back to 0° ("unlock"),
/// then the whole splash cross-fades out. Total ~1.1s.
///
/// This motif rhymes with RecoveryPhraseView's gold-hairline border draw so
/// the app's visual language is "gold hairlines sealing and unsealing things."
struct LaunchSplashView: View {
    let onFinished: () -> Void

    @State private var circleProgress: CGFloat = 0
    @State private var circleScale: CGFloat = 0.33    // 40pt / 120pt
    @State private var shieldOpacity: Double = 0
    @State private var lockRotation: Double = 0
    @State private var fadeOut: Double = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ZStack {
                Circle()
                    .trim(from: 0, to: circleProgress)
                    .stroke(Color.kataGold, style: StrokeStyle(lineWidth: 0.75, lineCap: .round))
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))
                    .scaleEffect(circleScale)

                ZStack {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 72, weight: .regular))
                        .foregroundStyle(LinearGradient(
                            colors: [.kataSapphire, .kataSapphire.opacity(0.7)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))

                    Image(systemName: "lock.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.kataGold)
                        .rotationEffect(.degrees(lockRotation))
                }
                .opacity(shieldOpacity)
            }
        }
        .opacity(1 - fadeOut)
        .task { await runAnimation() }
    }

    private func runAnimation() async {
        // Stage 1 — 0.0 → 0.6s: circle draws + scales, shield fades in
        withAnimation(.easeOut(duration: 0.6)) {
            circleProgress = 1.0
            circleScale = 1.0
        }
        withAnimation(.easeIn(duration: 0.45).delay(0.15)) {
            shieldOpacity = 1.0
        }

        try? await Task.sleep(nanoseconds: 900_000_000)  // t = 0.9s

        // Stage 2 — lock "unlock" micro-rotation
        withAnimation(.easeInOut(duration: 0.12)) {
            lockRotation = -15
        }
        try? await Task.sleep(nanoseconds: 140_000_000)
        withAnimation(.spring(duration: 0.18, bounce: 0.4)) {
            lockRotation = 0
        }
        KataHaptic.unlocked.fire()

        try? await Task.sleep(nanoseconds: 260_000_000)  // t ≈ 1.3s

        // Stage 3 — cross-fade out
        withAnimation(.easeInOut(duration: 0.35)) {
            fadeOut = 1.0
        }
        try? await Task.sleep(nanoseconds: 360_000_000)
        onFinished()
    }
}

#Preview {
    LaunchSplashView(onFinished: {})
}
