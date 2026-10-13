import SwiftUI
import AppKit

/// Sign in with ChatGPT under the segmentation chooser (W36.seg-opt-siwc), shown when the chosen approach has a
/// ChatGPT voter. OpenAI's UI rules (https://developers.openai.com/siwc/ui-ux-guidelines): the button reads
/// "Continue with ChatGPT"; while the plan powers the requests the app says "Using ChatGPT plan" beside a "Manage
/// usage" link to ChatGPT's settings; a welcome is shown on the first sign-in only.
struct ChatGPTPlanControls: View {
    @Binding var routes: SegmentationRoutes
    @AppStorage(DefaultsKeys.segmentationChatGPTRoute) private var routeRaw = ChatGPTRoute.apiKey.rawValue
    @AppStorage(DefaultsKeys.chatGPTPlanWelcomeShown) private var welcomeShown = false

    @State private var signingIn = false
    @State private var signInTask: Task<Void, Never>?
    @State private var error: String?
    @State private var showWelcome = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let account = routes.chatGPTAccount {
                if routes.offersChatGPTRouteChoice {
                    Picker("Pay for ChatGPT", selection: $routeRaw) {
                        Text("By API key").tag(ChatGPTRoute.apiKey.rawValue)
                        Text("By your ChatGPT plan").tag(ChatGPTRoute.plan.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .accessibilityIdentifier("ap.segmentation.chatGPTRoute")
                    .onChange(of: routeRaw) { _, raw in routes.chatGPTRoute = ChatGPTRoute(rawValue: raw) ?? .apiKey }
                }
                HStack(spacing: 8) {
                    if routes.chatGPTByPlan {
                        Label("Using ChatGPT plan", systemImage: "checkmark.seal")
                            .font(.caption)
                            .accessibilityIdentifier("ap.segmentation.usingChatGPTPlan")
                    }
                    Link("Manage usage", destination: ChatGPTAuth.manageUsageURL).font(.caption)
                    Spacer()
                    Text(account).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Button("Sign out") {
                        Task {
                            await ChatGPTAuth.shared.signOut()
                            routes = SegmentationRoutes.current()
                        }
                    }
                    .controlSize(.small)
                }
            } else if signingIn {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser…").font(.caption)
                    Button("Cancel") { signInTask?.cancel() }.controlSize(.small)
                }
            } else {
                HStack(spacing: 6) {
                    Button("Continue with ChatGPT", action: signIn)
                        .controlSize(.small)
                        .accessibilityIdentifier("ap.segmentation.chatGPTSignIn")
                    if routes.chatGPTStale {
                        // The saved registration would be reused; forgetting it lets another account sign in.
                        Button("Use a different account") {
                            Task {
                                await ChatGPTAuth.shared.signOut()
                                routes = SegmentationRoutes.current()
                            }
                        }
                        .controlSize(.small)
                    }
                    HelpButton(text: "Run ChatGPT's share of segmentation on your own ChatGPT plan instead of an OpenAI API key. You sign in on OpenAI's own page in your browser; Archive Processor never sees your password. ChatGPT reports no usage figure an app can read, so the cost shown is the token count and what the same calls would cost by API key. Your plan's own limits apply; see Manage usage in ChatGPT's settings.")
                }
            }
            if let error {
                Text(error).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        // A sign-in left waiting when the view goes away would hold the loopback port for its whole timeout.
        .onDisappear { signInTask?.cancel() }
        .alert("You're using your ChatGPT plan", isPresented: $showWelcome) {
            Button("Got it") { welcomeShown = true }
            Button("Manage usage") {
                welcomeShown = true
                NSWorkspace.shared.open(ChatGPTAuth.manageUsageURL)
            }
        } message: {
            Text("Eligible usage in this app uses your ChatGPT plan. Manage usage in your ChatGPT settings.")
        }
    }

    private func signIn() {
        error = nil
        signingIn = true
        signInTask = Task {
            do {
                _ = try await ChatGPTAuth.shared.signIn(open: { url in
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                })
                routes = SegmentationRoutes.current()
                if !welcomeShown { showWelcome = true }
            } catch where Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
            } catch {
                self.error = (error as? ChatGPTAuthError)?.description ?? error.localizedDescription
            }
            signingIn = false
        }
    }
}
