import Foundation

/// Who gets a seat in week 0. This is the lever every rollout plan budgets for.
public enum SeedingRule: String, CaseIterable, Sendable, Hashable, Codable {
    /// "Give it to the juniors, they have the most to gain." Selects by demographic.
    case juniorsFirst
    /// Seats handed out by lottery — what most "opt-in pilot" rollouts amount to.
    case random
    /// Seats to the engineers already writing the most code. Selects by activity.
    case mostActive
    /// Seats to the engineers with the most edges in the social graph.
    case mostConnected

    public var label: String {
        switch self {
        case .juniorsFirst: return "Juniors first"
        case .random: return "Random pilot"
        case .mostActive: return "Most active"
        case .mostConnected: return "Most connected"
        }
    }
}

/// A rollout policy is two independent decisions: who is seeded, and whether anyone
/// can *see* them using the tool. The second one is the lever nobody budgets for.
public struct RolloutPolicy: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let seeding: SeedingRule
    /// Week-0 seats. Every later adopter gets a seat on demand (seats are procurable).
    public let seats: Int
    /// Low (`StandardPolicies.invisible` = 0.15) = a CLI agent a teammate sees only by
    /// accident. 1 = engineered visibility: demo channels, "built with agent" PR labels,
    /// shared transcripts, pairing.
    public let peerVisibility: Double

    public init(name: String, seeding: SeedingRule, seats: Int, peerVisibility: Double) {
        precondition(seats >= 0, "seats must be non-negative")
        precondition((0...1).contains(peerVisibility), "peerVisibility must be in 0...1")
        self.name = name
        self.seeding = seeding
        self.seats = seats
        self.peerVisibility = peerVisibility
    }

    /// Engineer indices that receive a seat in week 0. Ties are broken by index so the
    /// result is deterministic; `random` draws from the supplied generator.
    public func seedIndices(in org: OrgGraph, using rng: inout SeededGenerator) -> [Int] {
        let cap = min(seats, org.count)
        guard cap > 0 else { return [] }
        let all = Array(org.engineers.indices)
        switch seeding {
        case .juniorsFirst:
            let ranked = all.sorted { a, b in
                let ra = rank(org.engineers[a].seniority), rb = rank(org.engineers[b].seniority)
                return ra == rb ? a < b : ra < rb
            }
            return Array(ranked.prefix(cap))
        case .random:
            var pool = all
            var picked: [Int] = []
            picked.reserveCapacity(cap)
            while picked.count < cap, !pool.isEmpty {
                let k = Int(rng.next() % UInt64(pool.count))
                picked.append(pool.remove(at: k))
            }
            return picked.sorted()
        case .mostActive:
            let ranked = all.sorted { a, b in
                let x = org.engineers[a].activity, y = org.engineers[b].activity
                return x == y ? a < b : x > y
            }
            return Array(ranked.prefix(cap))
        case .mostConnected:
            let ranked = all.sorted { a, b in
                let x = org.neighbors[a].count, y = org.neighbors[b].count
                return x == y ? a < b : x > y
            }
            return Array(ranked.prefix(cap))
        }
    }

    private func rank(_ s: Seniority) -> Int {
        switch s {
        case .junior: return 0
        case .mid: return 1
        case .senior: return 2
        }
    }
}

/// The behavioural constants. Defaults are calibrated to the *shape* of the Microsoft
/// findings (social spread, activity-driven retention, ~24% PR lift), not to its raw data,
/// which the paper does not publish at individual level.
public struct DiffusionParameters: Sendable, Hashable {
    /// Weekly chance an engineer tries the tool with zero peer exposure (the announcement email).
    public var spontaneousTryRate: Double
    /// Weekly chance scale from peer exposure: multiplied by (adopting-neighbour fraction × visibility).
    public var exposureRate: Double
    /// Weekly churn for an adopter with zero activity; scales down linearly with activity.
    public var churnCeiling: Double
    /// Fractional lift in merged PRs while an engineer is an active adopter.
    public var prLift: Double
    /// Merged PRs per week for an engineer at activity 1.0 before the tool.
    public var baselinePRsPerWeek: Double
    /// Token spend, in arbitrary units, per active adopter-week.
    public var tokenCostPerActiveWeek: Double

    public init(
        spontaneousTryRate: Double = 0.01,
        exposureRate: Double = 0.35,
        churnCeiling: Double = 0.18,
        prLift: Double = 0.24,
        baselinePRsPerWeek: Double = 3.0,
        tokenCostPerActiveWeek: Double = 1.0
    ) {
        self.spontaneousTryRate = spontaneousTryRate
        self.exposureRate = exposureRate
        self.churnCeiling = churnCeiling
        self.prLift = prLift
        self.baselinePRsPerWeek = baselinePRsPerWeek
        self.tokenCostPerActiveWeek = tokenCostPerActiveWeek
    }

    public static let `default` = DiffusionParameters()
}
