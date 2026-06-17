import SwiftUI

// MARK: - PasscodeLockView

/// Full-screen lock view shown on launch and for protected actions.
struct PasscodeLockView: View {

    enum Mode {
        case appLock
        case action(title: String, onSuccess: () -> Void, onCancel: (() -> Void)?)
    }

    let mode: Mode
    @StateObject private var pm = PasscodeManager.shared
    @State private var entered = ""
    @State private var shake = false
    @State private var errorMessage = ""
    @State private var attempts = 0

    private var title: String {
        switch mode {
        case .appLock:             return "Drive Vault is Locked"
        case .action(let t, _, _): return t
        }
    }

    private var showCancel: Bool {
        if case .action(_, _, let cancel) = mode { return cancel != nil }
        return false
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                lockIcon
                Text(title).font(.system(size: 18, weight: .semibold))
                dotIndicators
                if !errorMessage.isEmpty {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
                numpad
                biometricsButton
                cancelButton
            }
            .padding(40)
            .frame(width: 320)
        }
        .onAppear {
            if pm.isBiometricsEnabled { authenticateWithBiometrics() }
        }
    }

    // MARK: - Components

    private var lockIcon: some View {
        ZStack {
            Circle().fill(Color.purple.opacity(0.12)).frame(width: 72, height: 72)
            Image(systemName: "lock.fill").font(.system(size: 30)).foregroundStyle(.purple)
        }
    }

    private var dotIndicators: some View {
        HStack(spacing: 16) {
            ForEach(0..<pm.passcodeLength, id: \.self) { i in
                Circle()
                    .fill(i < entered.count ? Color.purple : Color.secondary.opacity(0.3))
                    .frame(width: 14, height: 14)
            }
        }
        .modifier(ShakeEffect(shake: shake))
    }

    private var biometricsButton: some View {
        Group {
            if pm.isBiometricsEnabled && pm.biometricsAvailable {
                Button { authenticateWithBiometrics() } label: {
                    Label("Use \(pm.biometricType)", systemImage: "faceid")
                        .font(.system(size: 13))
                        .foregroundStyle(.purple)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var cancelButton: some View {
        Group {
            if showCancel {
                Button("Cancel") {
                    if case .action(_, _, let cancel) = mode { cancel?() }
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Number Pad

    private var numpad: some View {
        VStack(spacing: 12) {
            ForEach([[1,2,3],[4,5,6],[7,8,9],[0]], id: \.self) { row in
                HStack(spacing: 20) {
                    ForEach(row, id: \.self) { digit in
                        if digit == 0 {
                            Button { deleteDigit() } label: {
                                Image(systemName: "delete.left")
                                    .font(.system(size: 18))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 64, height: 52)
                            }
                            .buttonStyle(.plain)
                            numButton(digit)
                            Color.clear.frame(width: 64, height: 52)
                        } else {
                            numButton(digit)
                        }
                    }
                }
            }
        }
    }

    private func numButton(_ digit: Int) -> some View {
        Button { appendDigit(digit) } label: {
            Text("\(digit)")
                .font(.system(size: 22, weight: .medium))
                .frame(width: 64, height: 52)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Input Handling

    private func appendDigit(_ digit: Int) {
        guard entered.count < pm.passcodeLength else { return }
        entered.append("\(digit)")
        errorMessage = ""
        if entered.count == pm.passcodeLength {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { verifyPasscode() }
        }
    }

    private func deleteDigit() {
        guard !entered.isEmpty else { return }
        entered.removeLast()
        errorMessage = ""
    }

    private func verifyPasscode() {
        if pm.verify(entered) {
            success()
        } else {
            attempts += 1
            entered = ""
            errorMessage = attempts >= 3 ? "Too many attempts. Try again." : "Incorrect passcode"
            withAnimation(.default) { shake = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { shake = false }
        }
    }

    private func authenticateWithBiometrics() {
        pm.authenticateWithBiometrics(reason: "Unlock Drive Vault") { ok in
            if ok { success() }
        }
    }

    private func success() {
        switch mode {
        case .appLock:
            pm.unlock()
        case .action(_, let onSuccess, _):
            onSuccess()
        }
    }
}

// MARK: - PasscodeSetupView

struct PasscodeSetupView: View {

    enum SetupMode { case create, change, disable }

    let mode: SetupMode
    let onDone: () -> Void

    @StateObject private var pm = PasscodeManager.shared
    @State private var step: Step = .enterNew
    @State private var first = ""
    @State private var second = ""
    @State private var current = ""
    @State private var shake = false
    @State private var errorMessage = ""
    @State private var selectedLength = 6

    enum Step { case verifyOld, enterNew, confirmNew }

    var body: some View {
        VStack(spacing: 28) {
            ZStack {
                Circle().fill(Color.purple.opacity(0.12)).frame(width: 72, height: 72)
                Image(systemName: stepIcon).font(.system(size: 30)).foregroundStyle(.purple)
            }

            Text(stepTitle).font(.system(size: 18, weight: .semibold))

            if step == .enterNew && mode != .disable {
                Picker("Length", selection: $selectedLength) {
                    Text("4-digit").tag(4)
                    Text("6-digit").tag(6)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .onChange(of: selectedLength) { _, _ in first = "" }
            }

            let length = mode == .disable ? pm.passcodeLength : selectedLength
            let currentEntry = step == .verifyOld ? current : (step == .enterNew ? first : second)

            HStack(spacing: 16) {
                ForEach(0..<length, id: \.self) { i in
                    Circle()
                        .fill(i < currentEntry.count ? Color.purple : Color.secondary.opacity(0.3))
                        .frame(width: 14, height: 14)
                }
            }
            .modifier(ShakeEffect(shake: shake))

            if !errorMessage.isEmpty {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            setupNumpad(length: length, entry: currentEntry)

            Button("Cancel", action: onDone)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
        }
        .padding(40)
        .frame(width: 320)
        .onAppear {
            step = (mode == .change || mode == .disable) ? .verifyOld : .enterNew
        }
    }

    private var stepTitle: String {
        switch step {
        case .verifyOld:  return "Enter current passcode"
        case .enterNew:   return mode == .disable ? "Enter passcode to disable" : "Create a passcode"
        case .confirmNew: return "Confirm passcode"
        }
    }

    private var stepIcon: String {
        switch step {
        case .verifyOld:  return "lock.fill"
        case .enterNew:   return "lock.open.fill"
        case .confirmNew: return "checkmark.shield.fill"
        }
    }

    private func setupNumpad(length: Int, entry: String) -> some View {
        VStack(spacing: 12) {
            ForEach([[1,2,3],[4,5,6],[7,8,9],[0]], id: \.self) { row in
                HStack(spacing: 20) {
                    ForEach(row, id: \.self) { digit in
                        if digit == 0 {
                            Button { deleteSetup() } label: {
                                Image(systemName: "delete.left")
                                    .font(.system(size: 18))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 64, height: 52)
                            }
                            .buttonStyle(.plain)
                            setupNumButton(digit, length: length)
                            Color.clear.frame(width: 64, height: 52)
                        } else {
                            setupNumButton(digit, length: length)
                        }
                    }
                }
            }
        }
    }

    private func setupNumButton(_ digit: Int, length: Int) -> some View {
        Button { appendSetup(digit, length: length) } label: {
            Text("\(digit)")
                .font(.system(size: 22, weight: .medium))
                .frame(width: 64, height: 52)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func appendSetup(_ digit: Int, length: Int) {
        errorMessage = ""
        switch step {
        case .verifyOld:
            guard current.count < pm.passcodeLength else { return }
            current.append("\(digit)")
            if current.count == pm.passcodeLength {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { verifyOld() }
            }
        case .enterNew:
            guard first.count < length else { return }
            first.append("\(digit)")
            if first.count == length {
                if mode == .disable {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { disablePasscode() }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { step = .confirmNew }
                }
            }
        case .confirmNew:
            guard second.count < length else { return }
            second.append("\(digit)")
            if second.count == length {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { confirmPasscode() }
            }
        }
    }

    private func deleteSetup() {
        errorMessage = ""
        switch step {
        case .verifyOld:  if !current.isEmpty { current.removeLast() }
        case .enterNew:   if !first.isEmpty   { first.removeLast() }
        case .confirmNew: if !second.isEmpty  { second.removeLast() }
        }
    }

    private func verifyOld() {
        if pm.verify(current) {
            step = .enterNew
            current = ""
        } else {
            current = ""
            errorMessage = "Incorrect passcode"
            triggerShake()
        }
    }

    private func disablePasscode() {
        if pm.verify(first) {
            pm.removePasscode()
            onDone()
        } else {
            first = ""
            errorMessage = "Incorrect passcode"
            triggerShake()
        }
    }

    private func confirmPasscode() {
        if first == second {
            pm.setPasscode(first)
            onDone()
        } else {
            second = ""
            first = ""
            step = .enterNew
            errorMessage = "Passcodes don't match — try again"
            triggerShake()
        }
    }

    private func triggerShake() {
        withAnimation(.default) { shake = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { shake = false }
    }
}

// MARK: - PasscodeGate

struct PasscodeGate<Content: View>: View {
    let actionTitle: String
    @ViewBuilder let content: Content
    @StateObject private var pm = PasscodeManager.shared
    @State private var authenticated = false
    @State private var showAuth = false

    var body: some View {
        Group {
            if pm.isPasscodeEnabled && !authenticated {
                VStack(spacing: 20) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.purple)
                    Text("This area is protected").font(.headline)
                    Text("Authenticate to access \(actionTitle)")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Authenticate") { showAuth = true }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .sheet(isPresented: $showAuth) {
                    PasscodeLockView(mode: .action(
                        title: "Authenticate",
                        onSuccess: { authenticated = true; showAuth = false },
                        onCancel: { showAuth = false }
                    ))
                }
            } else {
                content
            }
        }
    }
}

// MARK: - ShakeEffect

struct ShakeEffect: ViewModifier {
    var shake: Bool
    func body(content: Content) -> some View {
        content
            .offset(x: shake ? -8 : 0)
            .animation(shake ? .easeInOut(duration: 0.05).repeatCount(5, autoreverses: true) : .default, value: shake)
    }
}
