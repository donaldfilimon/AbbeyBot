import SwiftUI
import SwiftData
import AbbeyCore

struct EquityResearchView: View {
    @Environment(AbbeyEngine.self) private var engine
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \EquityIdea.generatedAt, order: .reverse) private var ideas: [EquityIdea]

    var body: some View {
        VStack(spacing: 0) {
            disclaimerBanner

            if !engine.config.equityModuleEnabled {
                ContentUnavailableView(
                    "Equity module disabled",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("Enable ABBEY_EQUITY_MODULE_ENABLED in Settings to generate synthetic ideas.")
                )
            } else {
                List(ideas) { idea in
                    IdeaRow(idea: idea)
                }

                HStack {
                    Button("Generate one idea") {
                        generate(count: 1)
                    }
                    Button("Generate 5 ideas") {
                        generate(count: 5)
                    }
                    Spacer()
                }
                .padding()
            }
        }
        .navigationTitle("Equity Research")
    }

    private var disclaimerBanner: some View {
        Label(EquityIdea.disclaimer, systemImage: "info.circle")
            .font(.caption)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.15))
    }

    private func generate(count: Int) {
        var engineCopy = engine.equityEngine
        let generated = engineCopy.generateBatch(count: count, context: modelContext)
        try? modelContext.save()
        engine.equityEngine = engineCopy
        for idea in generated {
            Task { await engine.eventBus.publish(.equityIdeaGenerated(symbol: idea.symbol)) }
        }
    }
}

private struct IdeaRow: View {
    let idea: EquityIdea

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(idea.symbol).font(.headline.monospaced())
                Spacer()
                Text("score \(String(format: "%.2f", idea.syntheticScore))")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(scoreColor(idea.syntheticScore).opacity(0.2), in: Capsule())
                    .foregroundStyle(scoreColor(idea.syntheticScore))
            }
            Text(idea.thesisSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !idea.factorBreakdown.isEmpty {
                Text(idea.factorBreakdown
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key): \(String(format: "%.2f", $0.value))" }
                    .joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func scoreColor(_ score: Double) -> Color {
        switch score {
        case ..<0.4: return .red
        case 0.4..<0.65: return .orange
        default: return .green
        }
    }
}
