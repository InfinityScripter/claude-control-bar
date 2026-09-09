import SwiftUI

/// The pages of the Settings window.
///
/// A flat list, not the sectioned and searchable sidebar a large app needs: there are four pages,
/// and a search field over four rows is furniture rather than navigation. The shape is here to
/// grow into — a case added here shows up in the sidebar and in the switch below, and nowhere
/// else has to be told about it.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, motion, sounds

    /// The page itself, so the sidebar's selection is a page rather than a raw string.
    var id: SettingsPage { self }

    var title: String {
        switch self {
        case .general:    return "General"
        case .appearance: return "Appearance"
        case .motion:     return "Motion"
        case .sounds:     return "Sounds"
        }
    }

    var icon: String {
        switch self {
        case .general:    return "gearshape"
        case .appearance: return "paintbrush"
        case .motion:     return "wand.and.rays"
        case .sounds:     return "speaker.wave.2"
        }
    }
}

/// Everything that used to sit under Options in the dropdown. It moved out because a menu that is
/// read at a glance — which sessions are running, which servers answered, how much of the limit is
/// gone — should not also be where an animation style gets picked.
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var page: SettingsPage? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                ForEach(SettingsPage.allCases) { item in
                    Label(item.title, systemImage: item.icon).tag(item)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 168, ideal: 180, max: 220)
        } detail: {
            detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // .balanced rather than .prominentDetail: the sidebar is four rows and never needs to be
        // collapsed out of the way, and the detail pane is the same width either way.
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var detail: some View {
        // An unset selection is only possible for the instant before the sidebar settles; General
        // is what the window opens on, so it is also what an empty selection shows.
        switch page ?? .general {
        case .general:    GeneralSettings(store: store)
        case .appearance: AppearanceSettings(store: store)
        case .motion:     MotionSettings(store: store)
        case .sounds:     SoundsSettings(store: store)
        }
    }
}

private struct GeneralSettings: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Menu bar") {
                // "in menu bar", because the dropdown rows keep their own timers regardless: a
                // switch reading "Show timer" that leaves timers visible reads as broken.
                Toggle("Timer in menu bar", isOn: store.showTimer)
                Toggle("Thinking words", isOn: store.thinkingWords)
            }
            Section {
                Toggle("Limits via Anthropic API", isOn: store.oauthLimits)
            } header: {
                Text("Limits")
            } footer: {
                Text("Polls Anthropic's usage endpoint with your own Claude OAuth token, which is "
                     + "sent to api.anthropic.com and nowhere else. With this off, the 5h and 7d "
                     + "bars only move when a status line happens to write them.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppearanceSettings: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker("Animation", selection: store.animStyle) {
                    ForEach(StatusController.AnimStyle.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                    }
                }
                Picker("Color", selection: store.iconSystem) {
                    Text("Orange").tag(false)
                    Text("System").tag(true)
                }
            } header: {
                Text("Menu bar icon")
            } footer: {
                Text("System draws the icon as a template — black on a light menu bar, white on a "
                     + "dark one — the way every other menu bar icon behaves. Orange keeps the "
                     + "brand colour on both.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct MotionSettings: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker("Level", selection: store.motionLevel) {
                    ForEach(Motion.Level.allCases, id: \.self) { level in
                        Text(level.title).tag(level)
                    }
                }
            } header: {
                Text("Animation in the menu")
            } footer: {
                Text(store.motionLevel.wrappedValue.detail)
            }
            // Said here rather than left as a mystery: with Reduce Motion on, picking Expressive
            // changes very little, and a setting that visibly does nothing reads as broken.
            if Motion.systemReducesMotion {
                Section {
                    Label("Reduce Motion is on in System Settings, so movement is replaced by a "
                          + "crossfade whatever is picked above.",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SoundsSettings: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker("Chime", selection: store.soundThreshold) {
                    Text("Off").tag(0.0)
                    Text("Every turn").tag(0.1)
                    Text("1 min+").tag(60.0)
                    Text("5 min+").tag(300.0)
                    Text("15 min+").tag(900.0)
                }
            } header: {
                Text("When a turn finishes")
            } footer: {
                Text("A threshold rather than a switch: a chime after every two-second turn is "
                     + "noise, one after a turn you walked away from is the point.")
            }
            Section {
                Picker("Sound", selection: store.needsYouSound) {
                    Text("Off").tag("")
                    ForEach(NeedsYouSound.choices, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            } header: {
                Text("When Claude needs you")
            } footer: {
                Text("Picking a sound plays it once. Nothing is played when the session's own "
                     + "window is already the one you are looking at.")
            }
        }
        .formStyle(.grouped)
    }
}
