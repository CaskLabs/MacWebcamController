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
    @State private var launchAtLogin: Bool = false

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Color Scheme", selection: Binding(
                    get: { appearance },
                    set: { mode in
                        appearanceRaw = mode.rawValue
                        mode.apply()
                    }
                )) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section("General") {
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
