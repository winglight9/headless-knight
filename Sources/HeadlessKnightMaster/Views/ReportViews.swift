import HKMKit
import SwiftUI

struct CleanReportView: View {
    @EnvironmentObject private var state: AppState
    let report: Report

    var body: some View {
        PopupScaffold(status: .done, title: "无头骑士大师") {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    Text(report.headline)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    NoteText(text: report.durationText)
                        .padding(.top, 10)
                    NoteText(text: report.batteryText)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 42)
                .padding(.bottom, 30)

                PopupButton(title: "知道了", isEnabled: !state.isBusy) {
                    state.acknowledgeReport()
                }

                TinyText(text: "全程没有被打扰", alignment: .center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)

                DetailDisclosure(isExpanded: state.showDetail, onToggle: { state.toggleDetail() }) {
                    detailLines
                }
                .padding(.top, 10)
            }
        }
    }

    @ViewBuilder
    private var detailLines: some View {
        DetailLine(label: "区间", value: "\(ClockFormatter.timeOfDay(report.startedAt)) – \(ClockFormatter.timeOfDay(report.endedAt))")
        DetailLine(label: "时长", value: report.durationText)
        DetailLine(label: "电量", value: report.batteryText)
        DetailLine(label: "暗唤醒", value: "\(report.darkWakeCount) 次")
        DetailLine(label: "通知唤醒", value: "\(report.notificationWakeCount) 次")
        DetailLine(label: "真实唤醒", value: "\(report.realWakeCount) 次")
        if report.rebooted {
            DetailLine(label: "重启", value: "期间重启过，唤醒记录只覆盖重启之后")
        }
        if !report.failedItems.isEmpty {
            DetailLine(label: "未完成", value: report.failedItems.joined(separator: "；"))
        }
    }
}

struct AnomalyReportView: View {
    @EnvironmentObject private var state: AppState
    let report: Report

    var body: some View {
        PopupScaffold(status: .attention, title: "无头骑士大师") {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    Text(report.headline)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(Theme.red)
                    if let first = report.firstRealWakeText {
                        NoteText(text: first)
                            .padding(.top, 9)
                    }
                    Text(report.secondaryBatteryText)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiaryInk)
                        .padding(.top, 5)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 28)
                .padding(.bottom, 14)

                if let suggestion = report.suggestion {
                    WarningBox {
                        Text(suggestion.text)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.warningText)
                            .lineSpacing(3)
                    }
                    .padding(.top, 12)
                }

                PopupButton(title: "知道了", isEnabled: !state.isBusy) {
                    state.acknowledgeReport()
                }
                .padding(.top, 12)

                DetailDisclosure(isExpanded: state.showDetail, onToggle: { state.toggleDetail() }) {
                    detailLines
                }
                .padding(.top, 12)
            }
        }
    }

    @ViewBuilder
    private var detailLines: some View {
        DetailLine(label: "区间", value: "\(ClockFormatter.timeOfDay(report.startedAt)) – \(ClockFormatter.timeOfDay(report.endedAt))")
        DetailLine(label: "时长", value: report.durationText)
        DetailLine(label: "电量", value: report.batteryText)
        DetailLine(label: "暗唤醒", value: "\(report.darkWakeCount) 次")
        DetailLine(label: "通知唤醒", value: "\(report.notificationWakeCount) 次")
        ForEach(report.realWakes) { wake in
            DetailLine(label: "真实唤醒", value: "\(wake.headlineText)（\(wake.reason)）")
        }
        if !report.sleptAtAll {
            DetailLine(label: "睡眠", value: "整段时间没有一条进入睡眠的记录")
        }
        if report.rebooted {
            DetailLine(label: "重启", value: "期间重启过，唤醒记录只覆盖重启之后")
        }
        if !report.failedItems.isEmpty {
            DetailLine(label: "未完成", value: report.failedItems.joined(separator: "；"))
        }
    }
}

struct DetailLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryInk)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
