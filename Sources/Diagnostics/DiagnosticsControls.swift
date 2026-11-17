import AdapterTracking
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import WebKit

/// Rendering and input lab: contributor tools for comparing rendering paths and input delivery.
struct DiagnosticsControls: View {
    @ObservedObject private var browser = BrowserScreen.shared
    @ObservedObject private var workspace = BrowserScreen.shared.workspace
    @ObservedObject private var native = NativeInput.shared
    @ObservedObject private var tracking = GlassesDisplay.shared.tracking
    @State private var showSettings = false
    @FocusState private var phoneEditorFocused: Bool
    @ObservedObject private var phone = GlassesDisplay.shared.phone
    @ObservedObject private var display = GlassesDisplay.shared
    var body: some View {
        ZStack(alignment: .top) {
            if native.phoneHosted {
                CoveredPhoneWebSource().frame(height: 230).accessibilityHidden(true)
            }
            VStack(spacing: 8) {
                HStack {
                    Spacer()
                    Button(showSettings ? "Trackpad" : "Settings") {
                        showSettings.toggle()
                    }
                }.padding(.horizontal, 12).padding(.top, 8)
                if let popup = browser.popup {
                    HStack {
                        Text("In-app login: \(browser.popupHost)").font(.footnote)
                        Spacer()
                        Button("Close") {
                            browser.closePopup()
                        }
                    }.padding(.horizontal, 12)
                    LoginWebView(web: popup)
                } else if showSettings {
                    settings
                } else {
                    controller
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        }
        .onDisappear {
            native.cancel("Web controls closed.")
        }
    }
    private var controller: some View {
        VStack(spacing: 8) {
            Picker("Input", selection: $workspace.input) {
                ForEach(WebInput.allCases) {
                    Text($0.rawValue).tag($0)
                }
            }.pickerStyle(.segmented)
            touchpad
            centerAndAimRow
            if !browser.workspace.centerMessage.isEmpty {
                Text(browser.workspace.centerMessage).font(.caption)
            }
            if let editor = browser.phoneEditor {
                phoneEditorField(editor)
            }
            if native.engine == .dom {
                TextField("DOM baseline: click a field first", text: $browser.keyboardText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: browser.keyboardText) { _ in
                        browser.sendText()
                    }
            }
            inputCheckControls
            Text(native.status).font(.caption).lineLimit(2)
        }.padding(.horizontal, 12).padding(.bottom, 8)
    }

    private var touchpad: some View {
        WebTouchpad(
            swipeToScroll: browser.workspace.input != .trackpad,
            move: {
                browser.moveCursor($0)
            },
            click: {
                browser.click()
            },
            scroll: {
                browser.scroll($0)
            },
            beginScroll: {
                browser.beginScroll()
            },
            stopScroll: {
                browser.cancelScroll()
            }, endScroll: browser.endScroll
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(!native.running)
    }

    private var centerAndAimRow: some View {
        HStack {
            Button(
                browser.workspace.centerCountdown > 0
                    ? "Centering in \(browser.workspace.centerCountdown)…" : "Center screen"
            ) {
                browser.schedulePanelCenter()
            }.disabled(!tracking.active || native.running || browser.workspace.centerCountdown > 0)
            Spacer()
            Button("Clear selection") {
                browser.clearWebSelection()
            }.disabled(native.running)
            if browser.workspace.input == .remote {
                Spacer()
                Button(aimButtonTitle) {
                    display.schedulePhoneAim()
                }.disabled(native.running || display.aimCountdown > 0)
            }
        }
    }

    private var aimButtonTitle: String {
        if display.aimCountdown > 0 {
            return "Aiming in \(display.aimCountdown)…"
        }
        return phone.aimReady ? "Aim again" : "Aim phone"
    }

    private func phoneEditorField(_ editor: BrowserScreen.PhoneEditor) -> some View {
        HStack {
            TextField(
                "Type on phone",
                text: Binding(
                    get: { browser.phoneEditor?.text ?? "" },
                    set: {
                        browser.updatePhoneEditor($0)
                    })
            )
            .textFieldStyle(.roundedBorder)
            .focused($phoneEditorFocused)
            .submitLabel(.done)
            .onSubmit {
                browser.closePhoneEditor()
            }
            Button("Done") {
                browser.closePhoneEditor()
            }
        }.id(editor.id).onAppear {
            phoneEditorFocused = true
        }
    }

    @ViewBuilder private var inputCheckControls: some View {
        if native.keyboardVisible {
            Button("Hide keyboard") {
                browser.closePhoneEditor()
                native.dismissKeyboard()
            }
        } else {
            HStack {
                Button(native.running ? "Checking…" : "Run input check") {
                    native.run()
                }.disabled(native.running)
                Spacer()
            }
            if native.phoneHosted && browser.isFixture {
                IsolatedEventHold().frame(height: 44).allowsHitTesting(!native.running)
            }
        }
    }

    private var settings: some View {
        Form {
            displaySection
            phoneInputSection
            nativeInputCheckSection
            testSourceSection
            Text("\(AppDelegate.displayNameAndVersion)").font(.footnote)
        }
    }

    private var displaySection: some View {
        Section("Display") {
            Picker("Rendering case", selection: $browser.backend) {
                ForEach(WebBackend.allCases) {
                    Text($0.rawValue).tag($0)
                }
            }.disabled(native.running).onChange(of: browser.backend) { _ in
                browser.modeChanged()
            }
            Text(browser.status).font(.footnote)
            Text("Head: \(tracking.status)").font(.footnote)
            Text("For stereo, use the glasses’ physical control to select SBS.").font(.footnote)
            Text(browser.metrics).font(.system(.footnote, design: .monospaced))
            Button(browser.running ? "Recording scroll run…" : "Run 10-second scroll test") {
                browser.runScrollTest()
            }
            .disabled(browser.running || native.running)
            ShareLink("Share report", item: browser.report)
        }
    }

    private var phoneInputSection: some View {
        Section("Phone input") {
            Picker("Scroll engine", selection: $workspace.scrollEngine) {
                ForEach(BrowserScreen.ScrollEngine.allCases) {
                    Text($0.rawValue).tag($0)
                }
            }
            Picker("Event delivery", selection: $native.engine) {
                ForEach(NativeInput.Engine.allCases) {
                    Text($0.rawValue).tag($0)
                }
            }.disabled(native.running)
            Text(browser.inputStatus).font(.footnote)
        }
    }

    private var nativeInputCheckSection: some View {
        Section("Native input check") {
            Button(native.running ? "Checking input…" : "Run native input check") {
                native.run()
            }.disabled(
                native.running)
            Text(native.status).font(.footnote)
            LabeledContent("Keyboard notification", value: native.keyboardVisible ? "Visible" : "Hidden")
            Button("Dismiss keyboard") {
                native.dismissKeyboard()
            }
            Toggle("Hold screen centered for input", isOn: $native.freezePanel).disabled(native.running)
            DisclosureGroup("Event observations") {
                Text(native.eventSummary).font(.system(.caption, design: .monospaced))
            }
            Button(
                native.phoneHosted ? "Return source to external window" : "Try interactive phone source + portals"
            ) {
                native.setPhoneHost(!native.phoneHosted)
            }.disabled(native.running)
            Text(
                """
                The automatic check only targets the bundled fixture. A successful dispatch is not a trusted-event \
                verdict. If input fails externally, compare the same check with the phone source.
                """
            ).font(.footnote)
        }
    }

    private var testSourceSection: some View {
        Section("Test source") {
            Button("Reset bundled test page") {
                browser.loadFixture()
            }.disabled(native.running)
            TextField("Optional HTTPS page URL", text: $browser.urlText).textInputAutocapitalization(.never)
                .autocorrectionDisabled().keyboardType(.URL)
            Button("Load page") {
                browser.loadURL()
            }.disabled(native.running)
            Toggle("Request desktop website", isOn: $workspace.preferDesktop)
                .onChange(of: browser.workspace.preferDesktop) { _ in
                    browser.modeChanged()
                    browser.web.reload()
                }
            Text(
                """
                To compare protected playback, first check that the same protected video plays in the native \
                rendering mode.
                """
            ).font(.footnote)
            if browser.backend == .snapshot {
                Picker("Snapshot request cap", selection: $browser.snapshotFPS) {
                    Text("10 Hz").tag(10.0)
                    Text("30 Hz").tag(30.0)
                    Text("60 Hz").tag(60.0)
                }
                .onChange(of: browser.snapshotFPS) { _ in
                    browser.modeChanged()
                }
                Toggle("Wait for screen updates", isOn: $browser.snapshotAfterUpdates)
                    .onChange(of: browser.snapshotAfterUpdates) { _ in
                        browser.modeChanged()
                    }
                Text(
                    """
                    The live source thumbnail stays visible at the lower left. Metal presents the latest completed \
                    snapshot; source animation Hz and display Hz differ from snapshot Hz.
                    """
                ).font(.footnote)
            }
            if browser.backend == .portal {
                Text(browser.portalStatus).font(.footnote)
            }
            if browser.backend == .replica {
                Text(
                    """
                    Replicator is a zero-disparity control. It repeats the left projection; it does not prove \
                    binocular depth.
                    """
                ).font(.footnote)
            }
        }
    }
}

/// Keeps the web view in the phone window but hidden behind an opaque cover.
private struct CoveredPhoneWebSource: UIViewRepresentable {
    func makeUIView(context: Context) -> Container {
        Container()
    }
    func updateUIView(_ view: Container, context: Context) {
        view.setNeedsLayout()
    }
    final class Container: UIView {
        private let cover = UIView()
        override init(frame: CGRect) {
            super.init(frame: frame)
            cover.backgroundColor = .systemBackground
            cover.isOpaque = true
            cover.isAccessibilityElement = false
            addSubview(cover)
        }
        required init?(coder: NSCoder) {
            fatalError("Programmatic view")
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            cover.frame = bounds
            let source = NativeInput.shared.phoneContent
            if source.superview !== self {
                insertSubview(source, belowSubview: cover)
            }
            let size = NativeInput.phoneSourceSize
            let width = min(bounds.width, 360)
            source.bounds = CGRect(origin: .zero, size: size)
            let scale = width / size.width
            source.transform = CGAffineTransform(scaleX: scale, y: scale)
            source.center = CGPoint(x: bounds.midX, y: width * size.height / size.width / 2)
        }
    }
}

/// A touch area for checking input while a finger is held on the phone.
private struct IsolatedEventHold: UIViewRepresentable {
    func makeUIView(context: Context) -> HoldTarget {
        HoldTarget()
    }
    func updateUIView(_ uiView: HoldTarget, context: Context) {}
    final class HoldTarget: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            let label = UILabel()
            label.text = "Hold here: isolated-event check"
            label.font = .preferredFont(forTextStyle: .footnote)
            label.textAlignment = .center
            label.backgroundColor = .tertiarySystemBackground
            label.layer.cornerRadius = 12
            label.clipsToBounds = true
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: topAnchor),
                label.bottomAnchor.constraint(equalTo: bottomAnchor),
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.widthAnchor.constraint(equalToConstant: 220)
            ])
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
            hold.minimumPressDuration = 0.45
            addGestureRecognizer(hold)
            isAccessibilityElement = true
            accessibilityLabel = label.text
        }
        required init?(coder: NSCoder) {
            fatalError("Programmatic view")
        }
        @objc private func pressed(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began {
                NativeInput.shared.startHoldControl()
            }
            if [.ended, .failed, .cancelled].contains(gesture.state) {
                NativeInput.shared.releaseHoldControl()
            }
        }
    }
}

/// Shows a sign-in popup on the phone.
private struct LoginWebView: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView {
        web
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
