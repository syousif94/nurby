import SwiftUI

@main
struct NurbyApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// The start page, or the studio for the open design. One SolidCraft session and one agent
/// serve both.
struct RootView: View {
    @State private var design = DesignModel()
    @State private var agent = AgentSession()
    @State private var inStudio = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            if inStudio {
                StudioView(design: design, agent: agent, goHome: { withAnimation(.smooth) { inStudio = false } },
                           openSettings: { showSettings = true })
                    .transition(.opacity)
            } else {
                StartView(design: design, agent: agent, open: { withAnimation(.smooth) { inStudio = true } },
                          openSettings: { showSettings = true })
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView(agent: agent) }
        .task {
            if ProcessInfo.processInfo.arguments.contains("-NurbyDemo") {
                await design.newDesign()
                await design.buildDemo()
                inStudio = true
            } else if ProcessInfo.processInfo.arguments.contains("-NurbyStudio") {
                await design.restore()
                inStudio = true
            }
        }
    }
}
