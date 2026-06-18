import SwiftUI
import Charts

/// "Grandma plot": two rows of scatter dots — see at a glance whether the two clusters separate.
/// (Moved here from the old Screens.swift so the Ask/Archive cards keep working.)
struct NightlyStripPlot: View {
    let points: [(value: Double, group: String)]

    var body: some View {
        Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                PointMark(
                    x: .value("Value", p.value),
                    y: .value("Group", p.group)
                )
                .symbolSize(70)
                .opacity(0.85)
                .foregroundStyle(by: .value("Group", p.group))
            }
        }
        .chartForegroundStyleScale(range: [N1Design.warn, N1Design.signal])
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(.white.opacity(0.06))
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(label)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(N1Design.ink)
                    }
                }
            }
        }
        .frame(height: 130)
    }
}
