import Foundation

/// Seniority is the "demographic" axis. The Microsoft study (arXiv:2607.01418) found
/// retention was associated with coding activity, not demographics — so this model
/// deliberately makes seniority *irrelevant* to retention and lets policies that
/// select by seniority pay for that assumption.
public enum Seniority: String, CaseIterable, Sendable, Hashable, Codable {
    case junior, mid, senior
}

/// One engineer in the org graph.
public struct Engineer: Sendable, Hashable, Identifiable, Codable {
    public let id: Int
    public let team: Int
    public let seniority: Seniority
    /// Baseline coding activity in [0, 1]. Roughly "how much code were they already
    /// writing before the tool existed". Drives retention and the size of the PR lift.
    public let activity: Double

    public init(id: Int, team: Int, seniority: Seniority, activity: Double) {
        precondition((0...1).contains(activity), "activity must be in 0...1")
        self.id = id
        self.team = team
        self.seniority = seniority
        self.activity = activity
    }
}

/// An engineering org as an undirected social graph. Edges are "people whose work
/// you actually see": teammates plus a few cross-team collaborators.
public struct OrgGraph: Sendable, Hashable {
    public let engineers: [Engineer]
    /// `neighbors[i]` lists engineer *indices* (not ids) adjacent to engineer `i`.
    public let neighbors: [[Int]]

    public init(engineers: [Engineer], neighbors: [[Int]]) {
        precondition(engineers.count == neighbors.count, "one adjacency list per engineer")
        for (i, list) in neighbors.enumerated() {
            for j in list {
                precondition(j >= 0 && j < engineers.count && j != i, "bad edge \(i)->\(j)")
            }
        }
        self.engineers = engineers
        self.neighbors = neighbors
    }

    public var count: Int { engineers.count }

    public func indices(where predicate: (Engineer) -> Bool) -> [Int] {
        engineers.indices.filter { predicate(engineers[$0]) }
    }
}

/// Deterministic SplitMix64. Every simulation in this package is reproducible from a seed,
/// which is what makes the policy comparison in the article a fair A/B rather than noise.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform Double in [0, 1).
    public mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}

/// Builds a synthetic org that is *unfavourable to the model's own thesis on purpose*:
/// activity is drawn without reading seniority, and every engineer makes the same number
/// of in-team and cross-team edge *attempts* regardless of seniority (realised degree varies
/// because edges are reciprocal and de-duplicated, but it is not correlated with seniority —
/// `testDegreeIsNotCorrelatedWithSeniority` pins that). If a seniority-based rollout loses
/// here, it loses on retention alone, not because juniors were drawn as isolated.
public enum OrgFixture {
    public static func make(
        teams: Int = 12,
        perTeam: Int = 10,
        inTeamDegree: Int = 4,
        crossTeamDegree: Int = 2,
        seed: UInt64 = 42
    ) -> OrgGraph {
        precondition(teams > 1 && perTeam > inTeamDegree && inTeamDegree >= 0 && crossTeamDegree >= 0)
        var rng = SeededGenerator(seed: seed)
        var engineers: [Engineer] = []
        engineers.reserveCapacity(teams * perTeam)

        for team in 0..<teams {
            for slot in 0..<perTeam {
                let seniority = Seniority.allCases[slot % Seniority.allCases.count]
                // Beta-ish skew: most engineers are mid-activity, a long tail is very active.
                let raw = (rng.unit() + rng.unit() + rng.unit()) / 3.0
                let activity = min(1.0, max(0.0, raw * raw * 1.6 + 0.05))
                engineers.append(Engineer(id: engineers.count, team: team, seniority: seniority, activity: activity))
            }
        }

        var adjacency = Array(repeating: Set<Int>(), count: engineers.count)
        func link(_ a: Int, _ b: Int) {
            guard a != b else { return }
            adjacency[a].insert(b)
            adjacency[b].insert(a)
        }

        for i in engineers.indices {
            let team = engineers[i].team
            let teammates = engineers.indices.filter { engineers[$0].team == team && $0 != i }
            let others = engineers.indices.filter { engineers[$0].team != team }
            for _ in 0..<inTeamDegree where !teammates.isEmpty {
                link(i, teammates[Int(rng.next() % UInt64(teammates.count))])
            }
            for _ in 0..<crossTeamDegree where !others.isEmpty {
                link(i, others[Int(rng.next() % UInt64(others.count))])
            }
        }

        return OrgGraph(engineers: engineers, neighbors: adjacency.map { $0.sorted() })
    }
}
