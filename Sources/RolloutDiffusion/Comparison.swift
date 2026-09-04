import Foundation

/// The four policies the article compares. Same org, same seed, same seat count —
/// the only things that vary are *who* is seeded and whether peers can *see* them.
public enum StandardPolicies {
    public static let seats = 24
    public static let invisible = 0.15   // a CLI agent: a teammate sees it only by accident
    public static let visible = 1.0      // engineered visibility

    public static let all: [RolloutPolicy] = [
        RolloutPolicy(name: "Juniors first · invisible", seeding: .juniorsFirst, seats: seats, peerVisibility: invisible),
        RolloutPolicy(name: "Juniors first · visible", seeding: .juniorsFirst, seats: seats, peerVisibility: visible),
        RolloutPolicy(name: "Most active · invisible", seeding: .mostActive, seats: seats, peerVisibility: invisible),
        RolloutPolicy(name: "Most active · visible", seeding: .mostActive, seats: seats, peerVisibility: visible),
    ]
}

/// Final-week metrics for one policy, averaged over several seeds.
public struct EnsembleOutcome: Sendable, Hashable, Identifiable {
    public var id: String { policy.name }
    public let policy: RolloutPolicy
    public let seedCount: Int
    public let meanTried: Double
    public let meanActive: Double
    public let meanLiftedPRs: Double
    public let meanTokenCost: Double

    public var meanRetention: Double { meanTried == 0 ? 0 : meanActive / meanTried }
    public var meanCostPerLiftedPR: Double { meanLiftedPRs <= 0 ? .infinity : meanTokenCost / meanLiftedPRs }
}

/// Runs several policies against one org with one seed and ranks them.
public struct PolicyComparison: Sendable {
    public let results: [RolloutResult]
    public let weeks: Int
    public let seed: UInt64

    public init(
        org: OrgGraph = OrgFixture.make(),
        policies: [RolloutPolicy] = StandardPolicies.all,
        parameters: DiffusionParameters = .default,
        weeks: Int = 16,
        seed: UInt64 = 7
    ) {
        let sim = DiffusionSimulator(org: org, parameters: parameters)
        self.results = policies.map { sim.run($0, weeks: weeks, seed: seed) }
        self.weeks = weeks
        self.seed = seed
    }

    /// Best policy by engineers still active at the end of the horizon.
    public var mostRetained: RolloutResult? {
        results.max { $0.final.active < $1.final.active }
    }

    /// Best policy by token spend per lifted PR (lower is better).
    public var cheapestPerLiftedPR: RolloutResult? {
        results.min { $0.costPerLiftedPR < $1.costPerLiftedPR }
    }

    /// Runs every policy across `seedCount` seeds and averages the final-week metrics,
    /// so a claim like "visibility doubles reach" is not an artefact of one lucky draw.
    public static func ensemble(
        org: OrgGraph = OrgFixture.make(),
        policies: [RolloutPolicy] = StandardPolicies.all,
        parameters: DiffusionParameters = .default,
        weeks: Int = 16,
        seedCount: Int = 20
    ) -> [EnsembleOutcome] {
        precondition(seedCount > 0, "seedCount must be positive")
        let sim = DiffusionSimulator(org: org, parameters: parameters)
        return policies.map { policy in
            var tried = 0.0, active = 0.0, prs = 0.0, cost = 0.0
            for seed in 0..<seedCount {
                let f = sim.run(policy, weeks: weeks, seed: UInt64(seed) &* 0x9E37 &+ 1).final
                tried += Double(f.everTried)
                active += Double(f.active)
                prs += f.cumulativeLiftedPRs
                cost += f.cumulativeTokenCost
            }
            let n = Double(seedCount)
            return EnsembleOutcome(
                policy: policy, seedCount: seedCount,
                meanTried: tried / n, meanActive: active / n,
                meanLiftedPRs: prs / n, meanTokenCost: cost / n
            )
        }
    }

    /// A compact, alignment-free text table for READMEs, tests and logs.
    public func summaryTable() -> String {
        var lines = ["policy | tried | active | lapsed | retention | lifted PRs | cost/PR"]
        for r in results {
            let f = r.final
            lines.append(
                "\(r.policy.name) | \(f.everTried) | \(f.active) | \(f.lapsed) | "
                + String(format: "%.0f%%", f.retentionRate * 100) + " | "
                + String(format: "%.0f", f.cumulativeLiftedPRs) + " | "
                + (r.costPerLiftedPR.isFinite ? String(format: "%.2f", r.costPerLiftedPR) : "∞")
            )
        }
        return lines.joined(separator: "\n")
    }
}
