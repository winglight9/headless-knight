import HKMKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        content
            .frame(width: Theme.width)
            .background(Theme.surface)
            .alert(
                "没能完成",
                isPresented: Binding(
                    get: { state.errorMessage != nil },
                    set: { if !$0 { state.errorMessage = nil } }
                ),
                actions: {
                    Button("知道了") { state.errorMessage = nil }
                },
                message: {
                    Text(state.errorMessage ?? "")
                }
            )
    }

    @ViewBuilder
    private var content: some View {
        switch state.screen {
        case let .onboarding(step):
            switch step {
            case 2: OnboardingTwoView()
            case 3: OnboardingThreeView()
            default: OnboardingOneView()
            }
        case .home:
            HomeView()
        case .detecting:
            DetectingView()
        case .blocked:
            BlockedView()
        case .readyToUnplug:
            ReadyToUnplugView()
        case .away:
            AwayView()
        case .auditing:
            AuditingView()
        case .report:
            if let report = state.report {
                if report.hasAnomaly {
                    AnomalyReportView(report: report)
                } else {
                    CleanReportView(report: report)
                }
            } else {
                HomeView()
            }
        case .settings:
            SettingsView()
        }
    }
}
