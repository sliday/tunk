import SwiftUI
import TunkEmit

/// The first-run window. Three steps: what Tunk is, the two permissions, and a
/// double-tap with live feedback. Sized for a fixed 560 × 640 window; nothing
/// in it scrolls.
///
/// Wording rules: no engineering vocabulary anywhere in here. The reasons for
/// each permission are the sentences from `README.md`, shortened.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size = CGSize(width: 560, height: 640)
    /// The app's one accent, used for the current step and the primary button
    /// so the window reads as Tunk rather than as a generic blue system sheet.
    static let amber = Color.tunkAmber

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 22)
                .padding(.bottom, 18)
            StepIndicator(current: model.step)
                .padding(.horizontal, 60)
                .padding(.bottom, 18)
            stepBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 28)
            footer
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
                .padding(.top, 12)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - header

    private var header: some View {
        VStack(spacing: 8) {
            AppMark(size: 60)
                .padding(.bottom, 4)
            Text("Welcome to Tunk")
                .font(.system(size: 26, weight: .bold))
            Text("Double-tap the body of your MacBook to run a shortcut, the way Back Tap "
               + "works on iPhone. Tunk reads only the accelerometer.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
        }
    }

    // MARK: - steps

    @ViewBuilder
    private var stepBody: some View {
        switch model.step {
        case .whatItDoes: WhatItDoesStep()
        case .permissions: PermissionsStep(model: model)
        case .tryIt: TryItStep(model: model)
        }
    }

    // MARK: - footer

    private var footer: some View {
        HStack(spacing: 12) {
            if model.step == .permissions {
                LaunchAtLoginToggle(model: model)
            } else if model.step == .tryIt {
                Text(model.settings.launchAtLoginEnabled
                     ? "Tunk starts at login."
                     : "Tunk will not start at login. Change that in the menu.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if model.step != .whatItDoes {
                Button("Back") { model.back() }
                    .buttonStyle(TunkButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            switch model.step {
            case .whatItDoes, .permissions:
                Button("Continue") { model.advance() }
                    .buttonStyle(OnboardingPrimaryStyle())
                    .disabled(!model.canContinue)
                    .keyboardShortcut(.defaultAction)
            case .tryIt:
                Button("Done") { model.complete() }
                    .buttonStyle(OnboardingPrimaryStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - step 1

private struct WhatItDoesStep: View {
    var body: some View {
        VStack(spacing: 10) {
            row("hand.tap", "Knock twice on the case",
                "Palm rest, lid, or the deck beside the trackpad. A firm double knock, "
                + "like Back Tap on iPhone.")
            row("waveform.path.ecg", "Tunk feels it through the accelerometer",
                "That is the only sensor it reads. Never the microphone, never the "
                + "camera, and nothing leaves your Mac.")
            row("keyboard", "Your shortcut runs",
                "A keyboard combination or a macOS Shortcut. Built for hands-free "
                + "dictation with VoiceInk, but the action is yours to choose.")
        }
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(OnboardingView.amber)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(OnboardingView.amber.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingCard()
    }
}

// MARK: - step 2

private struct PermissionsStep: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            PermissionRow(
                name: PermissionState.inputMonitoringName,
                why: PermissionState.inputMonitoringWhy,
                granted: model.permissions.inputMonitoring,
                open: model.openInputMonitoring)
            PermissionRow(
                name: PermissionState.accessibilityName,
                why: PermissionState.accessibilityWhy,
                granted: model.permissions.accessibility,
                open: model.openAccessibility)

            if model.inputMonitoringGrantedThisSession {
                relaunchOffer
                    .transition(.opacity)
            } else {
                note
            }
        }
        .tunkAnimation(.tunkSnappy, value: model.permissions, reduceMotion: reduceMotion)
        .tunkAnimation(.tunkSnappy, value: model.inputMonitoringGrantedThisSession,
                       reduceMotion: reduceMotion)
    }

    private var note: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.tertiary)
            Text("Grant each one in System Settings, then come back; this window updates "
               + "by itself. macOS hands Input Monitoring to a freshly opened Tunk, so "
               + "after that grant you will be offered a Relaunch that returns here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }

    private var relaunchOffer: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(OnboardingView.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text("Input Monitoring is granted. Tunk needs a fresh start to use it.")
                    .font(.system(size: 12, weight: .medium))
                Text("Relaunch quits and reopens Tunk, back on this step.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Relaunch Tunk") { model.relaunch() }
                .buttonStyle(TunkButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .fill(OnboardingView.amber.opacity(0.12)))
    }
}

private struct PermissionRow: View {
    let name: String
    let why: String
    let granted: Bool
    let open: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 14, weight: .semibold))
                Text(why)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            StatusPill(granted: granted)
            Button(PermissionState.openButtonTitle, action: open)
                .buttonStyle(TunkButtonStyle())
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .onboardingCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name), \(granted ? "granted" : "not granted")")
    }
}

/// "Granted" with a check, "Not granted" with a dot. Fixed width so the two
/// rows' buttons line up whatever the state.
private struct StatusPill: View {
    let granted: Bool

    var body: some View {
        HStack(spacing: 5) {
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
            } else {
                Circle().frame(width: 7, height: 7)
            }
            Text(granted ? "Granted" : "Not granted")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(granted ? Color.green : Color.red)
        .padding(.horizontal, 10)
        .frame(width: 112, height: 26)
        .background(Capsule().fill((granted ? Color.green : Color.red).opacity(0.13)))
    }
}

private struct LaunchAtLoginToggle: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(get: { model.launchAtLogin },
                                 set: { model.setLaunchAtLogin($0) })) {
                Text("Launch at login").font(.system(size: 13))
            }
            .toggleStyle(.checkbox)
            .tint(OnboardingView.amber)
            .frame(minHeight: Metrics.hitTarget)
            .contentShape(Rectangle())
            if let note = model.launchAtLoginNote {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 260, alignment: .leading)
            }
        }
    }
}

// MARK: - step 3

private struct TryItStep: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            feedback
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .onboardingCard()
            actionCard
        }
    }

    private var feedback: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(OnboardingView.amber.opacity(0.35), lineWidth: 2)
                    .frame(width: 84, height: 84)
                    .scaleEffect(reduceMotion ? 1 : 1 + 0.45 * model.pulse)
                    .opacity(0.2 + 0.8 * model.pulse)
                Circle()
                    .fill(OnboardingView.amber.opacity(0.18 + 0.5 * model.pulse))
                    .frame(width: 64, height: 64)
                    .scaleEffect(reduceMotion ? 1 : 1 + 0.12 * model.pulse)
                Image(systemName: model.feltRecently ? "checkmark" : "hand.tap.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(model.feltRecently ? Color.white : OnboardingView.amber)
                    .contentTransition(.opacity)
            }
            .frame(height: 110)
            .tunkAnimation(.tunkQuick, value: model.pulse, reduceMotion: reduceMotion)
            .tunkAnimation(.tunkSnappy, value: model.feltRecently, reduceMotion: reduceMotion)

            Text(model.feltRecently ? "Felt it" : "Double-tap your MacBook")
                .font(.system(size: 17, weight: .semibold))
                .contentTransition(.opacity)
                .tunkAnimation(.tunkSnappy, value: model.feltRecently, reduceMotion: reduceMotion)
            Text(statusLine)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            if !model.isListening {
                Button("Relaunch Tunk") { model.relaunch() }
                    .buttonStyle(TunkButtonStyle())
            }
        }
    }

    private var statusLine: String {
        if !model.isListening {
            return "Tunk is not listening yet. A fresh start usually fixes that "
                 + "after a permission was granted."
        }
        switch model.feltCount {
        case 0: return "Two firm knocks on the palm rest. The ring lights up for each one Tunk hears."
        case 1: return "1 double-tap felt. Your action ran."
        default: return "\(model.feltCount) double-taps felt. Your action ran each time."
        }
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.doubleTapAction {
            case .hotkey(let spec):
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Your double-tap presses")
                        .font(.system(size: 13, weight: .medium))
                    KeyCaps(text: spec.description)
                    Spacer(minLength: 0)
                }
                Text("To drive dictation, paste the same combination into VoiceInk → "
                   + "Settings → Shortcuts → Second Shortcut, recording mode \"toggle\". "
                   + "Your existing VoiceInk shortcut keeps working.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .shortcut(let name, _):
                Text(name.isEmpty
                     ? "Your double-tap runs a Shortcut, but none is chosen yet."
                     : "Your double-tap runs the Shortcut \u{201C}\(name)\u{201D}.")
                    .font(.system(size: 13, weight: .medium))
                Text("Change it any time under Settings → Actions.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case .none:
                Text("Your double-tap does nothing yet.")
                    .font(.system(size: 13, weight: .medium))
                Text("Pick a keyboard shortcut or a macOS Shortcut under Settings → Actions.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingCard()
    }
}

/// `Ctrl+Opt+Cmd+;` drawn as key caps, one per token.
private struct KeyCaps: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(text.split(separator: "+").enumerated()), id: \.offset) { _, token in
                Text(String(token))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .frame(minWidth: 26, minHeight: 24, maxHeight: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.08)))
            }
        }
        .accessibilityLabel(text)
    }
}

// MARK: - shared pieces

/// Three numbered circles joined by a line. The current one is amber and
/// filled; the ones behind it carry a check.
private struct StepIndicator: View {
    let current: OnboardingModel.Step

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(OnboardingModel.Step.allCases) { step in
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(fill(for: step))
                            .frame(width: 26, height: 26)
                        if step.rawValue < current.rawValue {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color.white)
                        } else {
                            Text("\(step.rawValue + 1)")
                                .font(.system(size: 12, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(step == current ? Color.white : Color.secondary)
                        }
                    }
                    Text(step.title)
                        .font(.system(size: 12, weight: step == current ? .semibold : .regular))
                        .foregroundStyle(step == current ? Color.primary : Color.secondary)
                        .fixedSize()
                }
                .frame(width: 96)
                .accessibilityLabel("Step \(step.rawValue + 1), \(step.title)"
                                    + (step == current ? ", current" : ""))
                if step != OnboardingModel.Step.allCases.last {
                    Rectangle()
                        .fill(step.rawValue < current.rawValue
                              ? OnboardingView.amber.opacity(0.6)
                              : Color.primary.opacity(0.12))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                }
            }
        }
    }

    private func fill(for step: OnboardingModel.Step) -> Color {
        if step.rawValue <= current.rawValue { return OnboardingView.amber }
        return Color.primary.opacity(0.08)
    }
}

/// The aluminium body with two amber cores, drawn rather than loaded so the
/// bare SwiftPM binary shows the same mark as the bundle.
struct AppMark: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(white: 0.86), Color(white: 0.62)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
            core(diameter: size * 0.19)
                .offset(x: -size * 0.11, y: size * 0.08)
            core(diameter: size * 0.13)
                .offset(x: size * 0.13, y: -size * 0.11)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.10), radius: 1, y: 0.5)
        .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
        .shadow(color: .black.opacity(0.06), radius: 16, y: 8)
        .accessibilityHidden(true)
    }

    private func core(diameter: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [Color(red: 1, green: 0.85, blue: 0.45),
                                          OnboardingView.amber],
                                 center: .center, startRadius: 0, endRadius: diameter / 2))
            .frame(width: diameter, height: diameter)
            .shadow(color: OnboardingView.amber.opacity(0.8), radius: diameter * 0.35)
    }
}

/// The primary action: amber, white text, same press behaviour as the panel's
/// buttons. Disabled reads as a paler amber, not grey, so "Continue" stays
/// recognisable while it waits on the permissions.
struct OnboardingPrimaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration)
    }

    private struct Chrome: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(isEnabled ? 1 : 0.85))
                .padding(.horizontal, 22)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                        .fill(OnboardingView.amber.opacity(isEnabled ? 1 : 0.45)))
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .tunkAnimation(.tunkQuick, value: configuration.isPressed,
                               reduceMotion: reduceMotion)
                .frame(minWidth: Metrics.hitTarget, minHeight: Metrics.hitTarget)
                .contentShape(Rectangle())
        }
    }
}

private extension View {
    /// A section container: concentric radius, three stacked shadows, no border.
    func onboardingCard() -> some View {
        background(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
        .shadow(color: .black.opacity(0.10), radius: 1, y: 0.5)
        .shadow(color: .black.opacity(0.07), radius: 6, y: 3)
        .shadow(color: .black.opacity(0.05), radius: 18, y: 10)
    }
}
