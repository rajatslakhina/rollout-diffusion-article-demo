import XCTest
@testable import RolloutDiffusion

final class OrgFixtureTests: XCTestCase {
    func testFixtureIsDeterministicAndWellFormed() {
        let a = OrgFixture.make(), b = OrgFixture.make()
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 120)
        for (i, peers) in a.neighbors.enumerated() {
            XCTAssertFalse(peers.contains(i), "no self-edges")
            XCTAssertEqual(peers, peers.sorted())
            for j in peers { XCTAssertTrue(a.neighbors[j].contains(i), "edges are undirected") }
        }
    }

    func testActivityIsNotAProxyForSeniority() {
        // The fixture must not smuggle the thesis in by drawing juniors as low-activity.
        let org = OrgFixture.make()
        var means: [Seniority: Double] = [:]
        for s in Seniority.allCases {
            let xs = org.engineers.filter { $0.seniority == s }.map(\.activity)
            means[s] = xs.reduce(0, +) / Double(xs.count)
        }
        let spread = means.values.max()! - means.values.min()!
        XCTAssertLessThan(spread, 0.15, "seniority groups should have comparable mean activity, got \(means)")
    }
}

final class SeedingTests: XCTestCase {
    let org = OrgFixture.make()

    func testJuniorsFirstSelectsOnlyJuniorsWhenEnoughExist() {
        var rng = SeededGenerator(seed: 1)
        let policy = RolloutPolicy(name: "j", seeding: .juniorsFirst, seats: 24, peerVisibility: 1)
        let seeds = policy.seedIndices(in: org, using: &rng)
        XCTAssertEqual(seeds.count, 24)
        XCTAssertTrue(seeds.allSatisfy { org.engineers[$0].seniority == .junior })
    }

    func testMostActiveSelectsTopActivity() {
        var rng = SeededGenerator(seed: 1)
        let policy = RolloutPolicy(name: "a", seeding: .mostActive, seats: 10, peerVisibility: 1)
        let seeds = Set(policy.seedIndices(in: org, using: &rng))
        let top = Set(org.engineers.indices.sorted { org.engineers[$0].activity > org.engineers[$1].activity }.prefix(10))
        XCTAssertEqual(seeds, top)
    }

    func testRandomIsReproducibleAndDistinct() {
        var r1 = SeededGenerator(seed: 9), r2 = SeededGenerator(seed: 9)
        let policy = RolloutPolicy(name: "r", seeding: .random, seats: 30, peerVisibility: 1)
        let a = policy.seedIndices(in: org, using: &r1)
        let b = policy.seedIndices(in: org, using: &r2)
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set(a).count, 30, "no duplicate seats")
    }

    func testSeatsAreCappedAtOrgSize() {
        var rng = SeededGenerator(seed: 1)
        let policy = RolloutPolicy(name: "all", seeding: .random, seats: 10_000, peerVisibility: 1)
        XCTAssertEqual(policy.seedIndices(in: org, using: &rng).count, org.count)
    }

    func testZeroSeatsSeedsNobody() {
        var rng = SeededGenerator(seed: 1)
        let policy = RolloutPolicy(name: "none", seeding: .mostActive, seats: 0, peerVisibility: 1)
        XCTAssertTrue(policy.seedIndices(in: org, using: &rng).isEmpty)
    }
}

final class SimulatorTests: XCTestCase {
    let org = OrgFixture.make()

    func testWeekZeroSnapshotMatchesSeats() {
        let sim = DiffusionSimulator(org: org)
        let policy = RolloutPolicy(name: "p", seeding: .mostActive, seats: 24, peerVisibility: 1)
        let r = sim.run(policy, weeks: 0, seed: 1)
        XCTAssertEqual(r.weekly.count, 1)
        XCTAssertEqual(r.final.active, 24)
        XCTAssertEqual(r.final.everTried, 24)
        XCTAssertEqual(r.final.cumulativeTokenCost, 0)
    }

    func testSameSeedSameResult() {
        let sim = DiffusionSimulator(org: org)
        let policy = StandardPolicies.all[1]
        XCTAssertEqual(sim.run(policy, weeks: 16, seed: 3), sim.run(policy, weeks: 16, seed: 3))
    }

    func testTriedIsMonotoneAndActivePlusLapsedEqualsTried() {
        let sim = DiffusionSimulator(org: org)
        for policy in StandardPolicies.all {
            let r = sim.run(policy, weeks: 16, seed: 5)
            XCTAssertEqual(r.weekly.count, 17)
            for (prev, next) in zip(r.weekly, r.weekly.dropFirst()) {
                XCTAssertGreaterThanOrEqual(next.everTried, prev.everTried)
                XCTAssertEqual(next.active + next.lapsed, next.everTried)
                XCTAssertGreaterThanOrEqual(next.cumulativeTokenCost, prev.cumulativeTokenCost)
            }
        }
    }

    func testNoSeatsAndNoSpontaneousUseMeansNothingHappens() {
        var p = DiffusionParameters.default
        p.spontaneousTryRate = 0
        let sim = DiffusionSimulator(org: org, parameters: p)
        let policy = RolloutPolicy(name: "dead", seeding: .random, seats: 0, peerVisibility: 1)
        let r = sim.run(policy, weeks: 16, seed: 1)
        XCTAssertEqual(r.final.everTried, 0)
        XCTAssertEqual(r.costPerLiftedPR, .infinity)
        XCTAssertEqual(r.costPerRetainedAdopter, .infinity)
    }

    func testActiveNeighbourFractionIgnoresLapsedPeers() {
        let sim = DiffusionSimulator(org: org)
        var states = Array(repeating: AdoptionState.unaware, count: org.count)
        let peers = org.neighbors[0]
        XCTAssertFalse(peers.isEmpty)
        for p in peers { states[p] = .lapsed(at: 1) }
        XCTAssertEqual(sim.activeNeighbourFraction(of: 0, in: states), 0)
        states[peers[0]] = .active(since: 0)
        XCTAssertEqual(sim.activeNeighbourFraction(of: 0, in: states), 1.0 / Double(peers.count), accuracy: 1e-12)
        XCTAssertEqual(sim.activeNeighbourFraction(of: -1, in: states), 0, "out-of-range index is safe")
        XCTAssertEqual(sim.activeNeighbourFraction(of: org.count, in: states), 0)
    }

    func testChurnDependsOnActivityOnly() {
        let sim = DiffusionSimulator(org: org)
        let engineers = org.engineers
        guard let hi = engineers.max(by: { $0.activity < $1.activity }),
              let lo = engineers.min(by: { $0.activity < $1.activity }) else { return XCTFail("empty org") }
        XCTAssertLessThan(sim.weeklyChurn(of: hi.id), sim.weeklyChurn(of: lo.id))
        XCTAssertEqual(sim.weeklyChurn(of: hi.id), 0.18 * (1 - hi.activity), accuracy: 1e-12)
        // Two engineers with equal activity churn identically, whatever their seniority.
        let probe = Engineer(id: 0, team: 0, seniority: .junior, activity: 0.5)
        let probe2 = Engineer(id: 1, team: 0, seniority: .senior, activity: 0.5)
        let tiny = OrgGraph(engineers: [probe, probe2], neighbors: [[1], [0]])
        let tinySim = DiffusionSimulator(org: tiny)
        XCTAssertEqual(tinySim.weeklyChurn(of: 0), tinySim.weeklyChurn(of: 1))
        XCTAssertEqual(sim.weeklyChurn(of: -1), 0, "out-of-range index is safe")
    }
}

final class ComparisonTests: XCTestCase {
    func testVisibilityRoughlyDoublesReachAtEqualSeats() {
        let e = PolicyComparison.ensemble(seedCount: 20)
        let jInvisible = e[0], jVisible = e[1], aInvisible = e[2], aVisible = e[3]
        XCTAssertGreaterThan(jVisible.meanTried, jInvisible.meanTried * 1.8)
        XCTAssertGreaterThan(aVisible.meanTried, aInvisible.meanTried * 1.8)
    }

    func testSeedingByActivityBeatsJuniorsOnRetentionWhileInvisible() {
        let e = PolicyComparison.ensemble(seedCount: 20)
        XCTAssertGreaterThan(e[2].meanRetention, e[0].meanRetention + 0.1)
        XCTAssertLessThan(e[2].meanCostPerLiftedPR, e[0].meanCostPerLiftedPR)
    }

    func testOnceVisibleSeedChoiceStopsMattering() {
        let e = PolicyComparison.ensemble(seedCount: 20)
        XCTAssertEqual(e[1].meanActive, e[3].meanActive, accuracy: 10)
    }

    func testSeatsForEveryoneLosesToTwentyFourSeatsPlusVisibility() {
        let everyone = RolloutPolicy(name: "everyone · invisible", seeding: .random, seats: 120, peerVisibility: StandardPolicies.invisible)
        let e = PolicyComparison.ensemble(policies: [everyone, StandardPolicies.all[1]], seedCount: 20)
        XCTAssertLessThan(e[0].meanActive, e[1].meanActive, "120 invisible seats retain fewer engineers than 24 visible ones")
        XCTAssertGreaterThan(e[0].meanTokenCost, e[1].meanTokenCost)
    }

    func testSummaryTableHasOneRowPerPolicy() {
        let c = PolicyComparison()
        XCTAssertEqual(c.summaryTable().split(separator: "\n").count, StandardPolicies.all.count + 1)
        XCTAssertNotNil(c.mostRetained)
        XCTAssertNotNil(c.cheapestPerLiftedPR)
    }
}
