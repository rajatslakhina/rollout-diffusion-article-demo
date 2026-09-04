#if canImport(SwiftUI) && canImport(Charts)
import SwiftUI
import Charts

/// Interactive front end for the diffusion model: pick who gets the seats, decide whether
/// peers can see the tool in use, and watch tried-vs-active diverge week by week.
public struct RolloutDemoView: View {
    @State private var seeding: SeedingRule = .juniorsFirst
    @State private var visible = false
    @State private var seats = Double(StandardPolicies.seats)
    @State private var seed = 7.0
    @State private var result: RolloutResult?
    @State private var ensemble: [EnsembleOutcome] = []

    private let org = OrgFixture.make()

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section("Rollout policy") {
                    Picker("Seed seats to", selection: $seeding) {
                        ForEach(SeedingRule.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle("Peers can see it in use", isOn: $visible)
                    LabeledContent("Week-0 seats") {
                        Text("\(Int(seats)) of \(org.count)").monospacedDigit()
                    }
                    Slider(value: $seats, in: 0...Double(org.count), step: 1)
                    LabeledContent("Seed") { Text("\(Int(seed))").monospacedDigit() }
                    Slider(value: $seed, in: 1...50, step: 1)
                }

                if let result {
                    Section("Week by week — \(result.policy.name)") {
                        chart(for: result)
                            .frame(height: 200)
                            .accessibilityLabel("Adoption curve for \(result.policy.name)")
                        let f = result.final
                        LabeledContent("Ever tried", value: "\(f.everTried)")
                        LabeledContent("Still active at week \(f.week)", value: "\(f.active)")
                        LabeledContent("Lapsed (paid for, not using)", value: "\(f.lapsed)")
                        LabeledContent("Retention", value: f.retentionRate.formatted(.percent.precision(.fractionLength(0))))
                        LabeledContent("Lifted merged PRs", value: f.cumulativeLiftedPRs.formatted(.number.precision(.fractionLength(0))))
                        LabeledContent("Token cost per lifted PR", value: result.costPerLiftedPR.formatted(.number.precision(.fractionLength(2))))
                    }
                }

                if !ensemble.isEmpty {
                    Section("Four policies, \(ensemble[0].seedCount) seeds each, same org") {
                        ForEach(ensemble) { e in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(e.policy.name).font(.headline)
                                Text("tried \(e.meanTried.formatted(.number.precision(.fractionLength(0)))) · active \(e.meanActive.formatted(.number.precision(.fractionLength(0)))) · retention \(e.meanRetention.formatted(.percent.precision(.fractionLength(0)))) · cost/PR \(e.meanCostPerLiftedPR.formatted(.number.precision(.fractionLength(2))))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Rollout Diffusion")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Run") { run() }
                }
            }
            .onAppear { run() }
        }
    }

    private func run() {
        let policy = RolloutPolicy(
            name: "\(seeding.label) · \(visible ? "visible" : "invisible")",
            seeding: seeding,
            seats: Int(seats),
            peerVisibility: visible ? StandardPolicies.visible : StandardPolicies.invisible
        )
        result = DiffusionSimulator(org: org).run(policy, weeks: 16, seed: UInt64(seed))
        ensemble = PolicyComparison.ensemble(org: org)
    }

    private func chart(for result: RolloutResult) -> some View {
        Chart {
            ForEach(result.weekly) { s in
                LineMark(x: .value("Week", s.week), y: .value("Engineers", s.everTried))
                    .foregroundStyle(by: .value("Series", "Ever tried"))
                LineMark(x: .value("Week", s.week), y: .value("Engineers", s.active))
                    .foregroundStyle(by: .value("Series", "Active"))
                AreaMark(x: .value("Week", s.week), yStart: .value("Active", s.active), yEnd: .value("Tried", s.everTried))
                    .foregroundStyle(.red.opacity(0.12))
            }
        }
        .chartForegroundStyleScale(["Ever tried": Color.gray, "Active": Color.accentColor])
        .chartYScale(domain: 0...org.count)
    }
}

#Preview {
    RolloutDemoView()
}
#endif
