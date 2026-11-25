import AppIntents

/// Opens the Phi finder. Bound by the user in Settings → Action Button → Shortcuts; this app does not assign the hardware button itself.
/// Lock-screen runs use the system authentication policy; this intent does not bypass the lock.
struct OpenFinderIntent: AppIntent {
    static let title: LocalizedStringResource = "打开取景"
    static let description = IntentDescription("打开观止取景，不自动拍摄。")

    /// iOS 18–25: bring the app forward before `perform()`. Deprecated in iOS 26 in favor of `supportedModes`.
    static let openAppWhenRun: Bool = true

    /// iOS 26+: official replacement for `openAppWhenRun = true`. Foreground first, then run — needed so a pending route can apply to a visible surface.
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    /// Require unlock on this device. Do not use `alwaysAllowed`, which would let the intent run while locked.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @MainActor
    func perform() async throws -> some IntentResult {
        FinderLaunchRouter.shared.requestOpenFinder()
        return .result()
    }
}

struct PhiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenFinderIntent(),
            phrases: [
                "用\(.applicationName)打开取景",
                "打开\(.applicationName)取景",
                "在\(.applicationName)里打开取景"
            ],
            shortTitle: "打开取景",
            systemImageName: "camera.viewfinder"
        )
    }
}
