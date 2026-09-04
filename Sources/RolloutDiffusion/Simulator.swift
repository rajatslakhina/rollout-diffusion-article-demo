import Foundation

/// Per-engineer adoption state. `lapsed` engineers still count as "tried" — they are the
/// seats a licensing-led rollout paid for and reports as adoption.
public enum AdoptionState: Sendable, Hashable, Codable {
    case unaware
    case active(since: Int)
    case lapsed(at: Int)

    public var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    public var hasTried: Bool {
        if case .unaware = self { return false }
        return true
    }
}

/// One row of the weekly time series.
public struct RolloutSnapshot: Sendable, Hashable, Codable, Identifiable {
    public var id: Int { week }
    public let week: Int
    public let everTried: Int
    public let active: Int
    public let lapsed: Int
    public let cumulativeLiftedPRs: Double
    public let cumulativeTokenCost: Double

    public var retentionRate: Double {
        everTried == 0 ? 0 : Double(active) / Double(everTried)
    }
}

/// The full outcome of one policy over one simulated horizon.
public struct RolloutResult: Sendable, Hashable, Identifiable {
    public var id: String { policy.name }
    public let policy: RolloutPolicy
    public let weekly: [RolloutSnapshot]
    public let finalStates: [AdoptionState]

    public var final: RolloutSnapshot {
        // `weekly` always contains at least the week-0 snapshot (see `DiffusionSimulator.run`).
        weekly[weekly.count - 1]
    }

    /// Token spend per engineer still active at the end of the horizon.
    public var costPerRetainedAdopter: Double {
        final.active == 0 ? .infinity : final.cumulativeTokenCost / Double(final.active)
    }

    /// Token spend per extra merged PR the rollout produced.
    public var costPerLiftedPR: Double {
        final.cumulativeLiftedPRs <= 0 ? .infinity : final.cumulativeTokenCost / final.cumulativeLiftedPRs
    }
}

/// A synchronous, discrete-week diffusion model:
///
/// 1. Unaware engineers try the tool with probability
///    `spontaneousTryRate + exposureRate × (active-neighbour fraction) × peerVisibility`.
/// 2. Active engineers lapse with probability `churnCeiling × (1 − activity)`.
///    Seniority never enters this step — that is the point.
/// 3. Each active adopter-week adds `activity × baselinePRsPerWeek × prLift` merged PRs
///    and `tokenCostPerActiveWeek` of spend.
///
/// Decisions in week *t* read the state at the end of week *t − 1*, so evaluation order
/// cannot leak into the result.
public struct DiffusionSimulator: Sendable {
    public let org: OrgGraph
    public let parameters: DiffusionParameters

    public init(org: OrgGraph, parameters: DiffusionParameters = .default) {
        self.org = org
        self.parameters = parameters
    }

    public func run(_ policy: RolloutPolicy, weeks: Int, seed: UInt64) -> RolloutResult {
        precondition(weeks >= 0, "weeks must be non-negative")
        var rng = SeededGenerator(seed: seed)
        var states = Array(repeating: AdoptionState.unaware, count: org.count)

        for i in policy.seedIndices(in: org, using: &rng) {
            states[i] = .active(since: 0)
        }

        var liftedPRs = 0.0
        var tokenCost = 0.0
        var weekly: [RolloutSnapshot] = []
        weekly.reserveCapacity(weeks + 1)
        weekly.append(snapshot(week: 0, states: states, prs: liftedPRs, cost: tokenCost))

        guard weeks > 0 else {
            return RolloutResult(policy: policy, weekly: weekly, finalStates: states)
        }

        for week in 1...weeks {
            let previous = states

            // Output and spend accrue for everyone active at the start of the week.
            for i in org.engineers.indices where previous[i].isActive {
                liftedPRs += org.engineers[i].activity * parameters.baselinePRsPerWeek * parameters.prLift
                tokenCost += parameters.tokenCostPerActiveWeek
            }

            for i in org.engineers.indices {
                switch previous[i] {
                case .unaware:
                    let exposure = activeNeighbourFraction(of: i, in: previous) * policy.peerVisibility
                    let p = min(1.0, parameters.spontaneousTryRate + parameters.exposureRate * exposure)
                    if rng.unit() < p { states[i] = .active(since: week) }
                case .active:
                    if rng.unit() < weeklyChurn(of: i) { states[i] = .lapsed(at: week) }
                case .lapsed:
                    break
                }
            }

            weekly.append(snapshot(week: week, states: states, prs: liftedPRs, cost: tokenCost))
        }

        return RolloutResult(policy: policy, weekly: weekly, finalStates: states)
    }

    /// Weekly probability that an active engineer stops using the tool. Reads activity only;
    /// `Seniority` is deliberately not an input.
    public func weeklyChurn(of i: Int) -> Double {
        guard i >= 0, i < org.count else { return 0 }
        return parameters.churnCeiling * (1.0 - org.engineers[i].activity)
    }

    /// Fraction of `i`'s neighbours who are currently active. Lapsed peers are invisible:
    /// nobody learns a tool from someone who stopped using it.
    public func activeNeighbourFraction(of i: Int, in states: [AdoptionState]) -> Double {
        guard i >= 0, i < org.neighbors.count else { return 0 }
        let peers = org.neighbors[i]
        guard !peers.isEmpty else { return 0 }
        let active = peers.reduce(0) { $0 + (states[$1].isActive ? 1 : 0) }
        return Double(active) / Double(peers.count)
    }

    private func snapshot(week: Int, states: [AdoptionState], prs: Double, cost: Double) -> RolloutSnapshot {
        var tried = 0, active = 0, lapsed = 0
        for s in states {
            switch s {
            case .unaware: break
            case .active: tried += 1; active += 1
            case .lapsed: tried += 1; lapsed += 1
            }
        }
        return RolloutSnapshot(
            week: week, everTried: tried, active: active, lapsed: lapsed,
            cumulativeLiftedPRs: prs, cumulativeTokenCost: cost
        )
    }
}
