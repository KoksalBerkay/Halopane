import UniformTypeIdentifiers
import SwiftUI
import WebKit
import SpatialMath
import AdapterTracking

// Settings on iPhone.
extension BrowserShell {
    var adBlockingSettings: some View {
        AdBlockingSettings(store: workspace.adSettings, bundled: workspace.contentBlocker)
    }

    var settings: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink("Ad blocking") { adBlockingSettings }
                }
                screenAndControlsSection
                websitesSection
                searchSection
                homeSection
                glassesSection
                troubleshootingSection
                advancedSection
                aboutSection
            }
            .navigationTitle("Browser Settings")
            .toolbar {
                Button("Done") {
                    browser.controllerSettings = false
                }
            }
        }
    }

    // App version, the source code and a way to support the project. Links open in Safari.
    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: AppDelegate.displayNameAndVersion)
            Link(destination: AppDelegate.sourceCodeURL) {
                Label("Source code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Link(destination: AppDelegate.supportURL) {
                Label("Buy me a coffee", systemImage: "cup.and.saucer")
            }
            Text("Halopane is free software under the GPL-3.0-or-later licence.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var screenAndControlsSection: some View {
        Section("Screen and controls") {
            Picker("Anchoring", selection: $workspace.anchorMode) {
                ForEach(PanelAnchorMode.allCases) {
                    Text($0.rawValue).tag($0)
                }
            }
            if workspace.anchorMode == .follow {
                LabeledContent("Follow dead zone", value: "\(Int(workspace.followDeadZone))°")
                Slider(value: $workspace.followDeadZone, in: 12...40, step: 1)
                LabeledContent(
                    "Follow speed",
                    value: workspace.followSpeed.formatted(.number.precision(.fractionLength(1))))
                Slider(value: $workspace.followSpeed, in: 2...10, step: 0.5)
            }
            Picker("Input", selection: $workspace.input) {
                ForEach(WebInput.allCases) {
                    Text($0.rawValue).tag($0)
                }
            }
            Toggle("Request desktop websites", isOn: $workspace.preferDesktop)
                .onChange(of: workspace.preferDesktop) { _ in
                    owner.allPanels.filter { !$0.phonePageActive }.forEach {
                        $0.reloadPage()
                    }
                }
            Button("Clear web selection") {
                browser.clearWebSelection()
            }
        }
    }

    private var websitesSection: some View {
        Section("Websites") {
            Picker("Appearance", selection: $workspace.websiteAppearance) {
                ForEach(WebsiteAppearance.allCases) {
                    Text($0.rawValue).tag($0)
                }
            }
            Text("Websites that support a device theme use this appearance.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var searchSection: some View {
        Section("Search") {
            Picker("Search engine", selection: $workspace.searchEngine) {
                ForEach(BrowserSearchEngine.allCases) {
                    Text($0.rawValue).tag($0)
                }
            }
        }
    }

    private var homeSection: some View {
        Section("Home") {
            NavigationLink("Organize Home shortcuts") {
                HomeShortcutOrganizer(store: workspace.homeShortcuts)
            }
        }
    }

    private var glassesSection: some View {
        Section("Glasses") {
            NavigationLink("Visible area") {
                VisibleAreaCalibration(workspace: workspace)
            }
            Toggle("Laser pointer in Phone Aim", isOn: $workspace.laserEnabled)
            Text(tracking.status)
            if display.hasExternalDisplay && !display.externalStereo {
                Text("Mono output. Use the glasses’ 3D control to switch to side-by-side.")
            }
            Toggle("Head motion prediction", isOn: $display.settings.predictionEnabled)
            if display.settings.predictionEnabled {
                LabeledContent(
                    "Extra prediction", value: "\(Int(display.settings.extraPredictionMilliseconds)) ms")
                Slider(value: $display.settings.extraPredictionMilliseconds, in: 0...30, step: 1)
            }
        }
    }

    private var troubleshootingSection: some View {
        Section {
            ShareLink("Share report", item: browser.report)
        } header: {
            Text("Troubleshooting")
        } footer: {
            Text(
                """
                Attach this to a bug report. It holds app, tracking, display and playback details, and names only \
                well-known services such as YouTube or Netflix. Other sites, page titles, files and typed text are \
                left out.
                """)
        }
    }

    private var advancedSection: some View {
        Section {
            Picker(
                "Spatial decoder",
                selection: Binding(get: { nativeMedia.stereoDecoder }, set: nativeMedia.setStereoDecoder)
            ) {
                ForEach(StereoDecoderChoice.allCases) {
                    Text($0.rawValue).tag($0)
                }
            }
            Toggle("MediaSource for streaming (experimental)", isOn: $workspace.mediaSourceExperiment)
            Text("For Netflix and HBO Max as desktop sites. Close and reopen the app after changing it.")
                .font(.footnote).foregroundStyle(.secondary)
            Picker("Xbox Cloud Gaming profile", selection: $owner.xboxCloudProfile) {
                ForEach(CloudGamingProfile.allCases) {
                    Text($0.label).tag($0)
                }
            }
            Picker("GeForce NOW profile", selection: $owner.geforceNowProfile) {
                ForEach(CloudGamingProfile.allCases) {
                    Text($0.label).tag($0)
                }
            }
            Picker("Amazon Luna profile", selection: $owner.lunaCloudProfile) {
                ForEach(CloudGamingProfile.allCases) {
                    Text($0.label).tag($0)
                }
            }
            Button("Open play.xbox.com") {
                focus = nil
                browser.controllerSettings = false
                browser.navigate(CloudGamingService.xboxAlternateAddress)
            }
            if owner.selectedPanel == 1 {
                NavigationLink("Rendering and input lab") {
                    DiagnosticsControls()
                }
            } else {
                Text("Select Screen 1 to open the rendering and input lab.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text(
                """
                For testing and development. Spatial decoder picks how Spatial Player decodes stereo video. The cloud \
                gaming profiles choose which version of each service loads; Web app supports paired controllers. \
                The lab compares rendering paths and input delivery.
                """)
        }
    }
}
