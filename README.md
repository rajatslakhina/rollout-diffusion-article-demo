# RolloutDiffusion

**A seat is not an adopter.** This package is a small, deterministic diffusion model of how
an agentic coding tool actually spreads through an engineering org — and why the lever
every rollout plan budgets for (seats) is not the lever that moves adoption (visible peer use).

It is the demo for the article *"I Gave Every Engineer a Seat. 24 Seats Plus Visibility
Kept More of Them."* — Article: (added after publish)

The model is calibrated to the **shape** of the findings in
[arXiv:2607.01418](https://arxiv.org/abs/2607.01418) (Murphy-Hill, Butler, Savelieva —
Microsoft's early-2026 rollout of Claude Code and Copilot CLI): first use spreads through
social networks, retention tracks coding activity rather than demographics, and adopters
merge ~24% more PRs. It is **not** fitted to the paper's data, which is not published at
individual level.

## What it shows

Same 120-engineer org, same 24 week-0 seats, same seeds, 16 weeks. Only two things vary:
**who** gets seeded and whether teammates can **see** the tool being used.

| Policy (mean of 20 seeds) | Ever tried | Active at wk 16 | Retention | Lifted PRs | Cost / lifted PR |
|---|---|---|---|---|---|
| Juniors first · invisible | 50 | 24 | 48% | 171 | 2.24 |
| Juniors first · visible | 110 | 52 | 47% | 340 | 2.35 |
| Most active · invisible | 55 | 37 | 67% | 289 | **1.75** |
| Most active · visible | 115 | 57 | 49% | 422 | 2.18 |
| *Everyone gets a seat · invisible* | 120 | 40 | 33% | 498 | 2.29 |

Four things fall out, and each has a test pinning it:

1. **Visibility roughly doubles reach at equal seats** (`testVisibilityRoughlyDoublesReachAtEqualSeats`).
2. **While the tool is invisible, seeding by activity beats seeding by seniority** on retention
   and on cost per lifted PR (`testSeedingByActivityBeatsJuniorsOnRetentionWhileInvisible`).
3. **Once use is visible, who you seeded stops mattering** — the network swamps the seed
   (`testOnceVisibleSeedChoiceStopsMattering`).
4. **120 invisible seats retain fewer engineers at week 16 than 24 visible ones**, at ~1.4× the
   token spend (`testSeatsForEveryoneLosesToTwentyFourSeatsPlusVisibility`).

The fixture is deliberately unfavourable to the thesis: activity is independent of seniority
and every engineer has the same number of in-team and cross-team edges. If "juniors first"
loses, it loses on retention, not because juniors were drawn as isolated.

## The model in three rules

```swift
// 1. Unaware engineers try the tool when they can see peers using it.
let exposure = activeNeighbourFraction(of: i, in: previous) * policy.peerVisibility
let p = min(1.0, parameters.spontaneousTryRate + parameters.exposureRate * exposure)

// 2. Adopters lapse in proportion to how little code they were already writing.
//    Seniority is never an input.
public func weeklyChurn(of i: Int) -> Double {
    parameters.churnCeiling * (1.0 - org.engineers[i].activity)
}

// 3. Every active adopter-week adds PRs and spends tokens.
liftedPRs += activity * parameters.baselinePRsPerWeek * parameters.prLift
tokenCost += parameters.tokenCostPerActiveWeek
```

Running a comparison is one line:

```swift
let outcomes = PolicyComparison.ensemble()          // four standard policies, 20 seeds
for o in outcomes {
    print(o.policy.name, o.meanActive, o.meanRetention, o.meanCostPerLiftedPR)
}
```

## What's in it

- `Sources/RolloutDiffusion/Model.swift` — `Engineer`, `Seniority`, `OrgGraph`, `SeededGenerator`
  (SplitMix64, so every run is reproducible), `OrgFixture`.
- `Policy.swift` — `SeedingRule` (juniors first / random / most active / most connected),
  `RolloutPolicy` (seats × peer visibility), `DiffusionParameters`.
- `Simulator.swift` — `DiffusionSimulator`, `AdoptionState`, `RolloutSnapshot`, `RolloutResult`.
  Synchronous weekly update; week *t* reads week *t−1* so evaluation order can't leak.
- `Comparison.swift` — `StandardPolicies`, `PolicyComparison`, `EnsembleOutcome`.
- `RolloutDemoView.swift` — SwiftUI + Swift Charts front end: pick a seeding rule, toggle
  visibility, drag the seat count, watch *tried* and *active* diverge.
- `Tests/RolloutDiffusionTests` — 18 tests covering the fixture, seeding rules, simulator
  invariants, edge cases (zero seats, out-of-range indices, seat caps) and the four findings.
- `Demo.xcodeproj` + `Demo/DemoApp.swift` — an iOS app that consumes the package via a local
  package reference, so one clone runs.

## How to run it

```bash
git clone https://github.com/rajatslakhina/rollout-diffusion-article-demo.git
cd rollout-diffusion-article-demo
open Demo.xcodeproj      # pick the Demo scheme, any iPhone Simulator, Build & Run
swift test               # library + 18 tests, no Xcode needed
```

No other setup. The app is iOS 17+, the package builds on macOS 14+ and Linux (the view
is behind `#if canImport(SwiftUI) && canImport(Charts)`).

## Verification status

- `swift build` and `swift test`: **passed, 18/18**, Swift 6.0.3 (Linux aarch64), Swift 6 language mode.
- `Demo.xcodeproj/project.pbxproj`: hand-authored; braces and parentheses balanced, no dangling object ids,
  `XCLocalSwiftPackageReference` with `relativePath = .`, `GENERATE_INFOPLIST_FILE = YES`, no `.executableTarget`.
- **Simulator run: not completed in this cycle.** Xcode on the build machine already had an
  unrelated production project open, and the pipeline's rule for that case is to stop rather
  than click through someone else's work. `Demo/Screenshots/` is therefore empty and says so.
  The demo view was reviewed by hand against iOS 17 SwiftUI and Swift Charts APIs.

## License

MIT — see `LICENSE`.
