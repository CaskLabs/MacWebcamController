import SwiftUI
import ServiceManagement

// MARK: - Appearance Preference

enum AppearanceMode: String, CaseIterable {
    case system = "System"
    case light  = "Light"
    case dark   = "Dark"

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @AppStorage("appearanceMode") private var appearanceRaw: String = AppearanceMode.system.rawValue
    @AppStorage("showPreviewInMenuBar") private var showPreviewInMenuBar = false
    @State private var launchAtLogin: Bool = false

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        Form {
            Section("Appearance") {
                HStack(spacing: 6) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Button(mode.rawValue) {
                            appearanceRaw = mode.rawValue
                            mode.apply()
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(appearance == mode ? Color.white : Color.primary)
                        .background(
                            appearance == mode ? Color.accentColor : Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                    }
                }
            }

            Section("General") {
                Toggle("Enable On-Demand Preview in Menu Bar", isOn: $showPreviewInMenuBar)

                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
            appearance.apply()
        }
    }

    private func setLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[Settings] Launch at login failed: \(error)")
            // Revert toggle if it failed
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }
}
