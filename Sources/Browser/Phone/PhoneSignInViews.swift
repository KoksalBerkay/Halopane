import UniformTypeIdentifiers
import SwiftUI
import WebKit
import SpatialMath
import AdapterTracking

/// Shows a sign-in page on the phone instead of in the glasses.
struct PhoneSignInView: View {
    @ObservedObject var browser: BrowserScreen
    @State private var showCode = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(browser.web.url?.host ?? "Sign-in").lineLimit(1)
                Spacer()
                Button("Return to glasses") {
                    browser.returnSignInToGlasses()
                }
            }.padding()
            HStack {
                Button("Reset keyboard") {
                    browser.restorePhoneSignInInput()
                }
                Spacer()
                if BrowserDestination.isGoogleAccountPage(browser.web.url) {
                    Button("Enter code") {
                        showCode = true
                    }
                }
            }.font(.footnote).padding(.horizontal).padding(.bottom, 8)
            if BrowserDestination.phoneSignInProvider(browser.web.url) == .microsoft {
                MicrosoftPasskeyHint()
            }
            BrowserPopup(web: browser.web)
        }
        .sheet(isPresented: $showCode) {
            SignInCodeSheet(browser: browser, owner: browser.owner, tracking: GlassesDisplay.shared.tracking)
        }
    }
}

/// A note for Microsoft sign-in, where passkeys need the phone.
struct MicrosoftPasskeyHint: View {
    var body: some View {
        Text("If Passkey isn’t listed, choose another sign-in option offered by Microsoft.")
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.bottom, 8)
    }
}

/// Enter a sign-in code on the phone and send it to the page.
private struct SignInCodeSheet: View {
    let browser: BrowserScreen
    @ObservedObject var owner: BrowserScreen
    @ObservedObject var tracking: AdapterTracking
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var code = ""
    @State private var sending = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Form {
                HStack {
                    Button("Recenter") {
                        owner.centerPanelNow()
                    }.disabled(
                        owner.workspace.fullScreen || !tracking.active)
                    Spacer()
                    if owner.workspace.fullScreen {
                        Button("Exit Full Screen") {
                            owner.toggleFullScreen()
                        }
                    }
                }
                TextField("Verification code", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focused)
                PasteButton(payloadType: String.self) { values in
                    code = values.first ?? ""
                    failed = false
                }
                if failed {
                    Text("No matching code field was found, or the code format wasn’t accepted.").foregroundStyle(
                        .secondary)
                }
                Button("Fill code on page") {
                    sending = true
                    browser.insertSignInCode(code) { filled in
                        sending = false
                        failed = !filled
                        if filled {
                            code = ""
                            dismiss()
                        }
                    }
                }.disabled(code.isEmpty || sending)
            }
            .navigationTitle("Verification code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                focused = true
            }
            .onDisappear {
                code = ""
            }
        }
    }
}

/// Shows a website popup on the phone.
struct BrowserPopup: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView {
        web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
