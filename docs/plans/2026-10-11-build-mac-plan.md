# Build Mac: plan (2026-10-11)

Tracker row: ARC-15. The owner chose the approach on 11 October 2026.

## Goal

This Mac (an M1 Ultra with 20 cores and 128 GB) has run at a load average around 78 for days, with 61 worktrees on its external SSD. A second Mac, the owner's MacBook Pro with an M4 Max and 128 GB, takes the heavy runs the owner starts: the push gate and the whole suite on a commit, targeted tests, the regression suite's tiers, the release room's checks and the performance records. This Mac keeps its capacity for agents, video and rendering. When the build Mac can't be reached, the same command runs here, as it does today.

## Decisions

- **Over SSH, from the owner's own Terminal** (owner, 2026-10-11). Agents keep building here: the sandbox their shells run in refuses connections to the local network (a connection to the router failed with "Operation not permitted"), and relaying their jobs through a helper on this Mac would route around it. An agent that needs a heavy run gives the owner the line to run, as the release room already does for `mise run release`, and reads the results that come back into the checkout.
- **The release room's checks run on the build Mac; the cut stays here** (owner, 2026-10-11). This Mac's keychain keeps the Developer ID identity, the notary profile and the Sparkle key, and none of them goes to the build Mac. The dry run signs with the Developer ID identity, so it stays here too.
- **The build Mac's performance runs are its own series** (owner, 2026-10-11). Per-Mac lines on the performance page come first (ARC-09); then the README's card moves to the M4 Max, since this Mac is rarely quiet enough to record (a load average of 8 or below).
- **The build Mac sits plugged in with its lid closed,** with a display or an HDMI dummy plug, so its desktop session stays awake (owner, 2026-10-11).
- Considered and not chosen: a self-hosted GitHub Actions runner fed through a private repository, which agents could reach through the proxy (it can't be attached to the public repository, where a pull request from a fork could run its own code on it); and running agent chats on the build Mac itself, which splits orchestration across two Macs. The runner remains the way to let agents use the build Mac later.

## What exists

- `scripts/push-gate.py` checks a commit in a worktree of its own (`../darkroom-push-gate`, with its own DerivedData) at one of four levels (checks, reference, suite, full), and remembers a pass by the commit's tree in `build/push-gate/passed/<tree>`. A push whose tree passed at the level it needs goes straight through.
- `scripts/e2e.py` builds a test copy of the app, starts its executable and drives it in a home of its own; it needs an unlocked desktop session, and with `--focus` a Mac nobody is using. It writes `build/e2e/<commit>-<time>/report.json`, and `mise run release` accepts a passing, clean release-tier report with focus for the commit from the release copy's `build/e2e/`.
- `scripts/perf-record.sh` builds Release and appends a record to `docs/performance/history.jsonl`, marked noisy above a load average of 8. `scripts/perf-kit.sh` already measures another Mac as its own series, by AirDrop, and `scripts/perf-card.py` draws the card from the M1 Ultra's quiet records.
- The gitignored inputs a checkout needs: the sample raws (2.1 GB, which `mise run fixtures` and `mise run fixtures-shoots` download from raw.pixls.us), vendored LibRaw (`vendor/build`, `vendor/cache`) and the Swift packages (`Tuist/.build`, 220 MB). The gate's DerivedData is 3.2 GB.
- This Mac runs macOS 26.6.2 and Xcode 26.6 (17F113). CI's runner skips the GPU tests, so they have only run on this M1 Ultra; `ProcessStabilityTests` leaves room for another GPU's rounding, but no other GPU has been measured against it.

## Architecture

- **`scripts/build-mac.py`, on this Mac,** run from the owner's Terminal:
  - `setup` runs `scripts/build-mac/setup.sh` there with this Mac's macOS and Xcode versions, and installs the agent; `status` says whether the build Mac answers (SSH with a 3-second timeout), whether its macOS and Xcode match this Mac's, what it's running and has queued, and its free disk.
  - `gate [<commit>] [--suite | --full]`, `test [<commit>] --scheme <scheme> [--only <Target/Suite>]`, `e2e [<commit>] [-- <e2e arguments>]`, `release-checks <commit>`, `perf [<commit>]`, `attach <job>` and `cancel <job>`.
  - It sends the commit with `git push` over SSH to the build Mac's clone, under `refs/build-mac/`, which the pre-push hook lets through; queues the job; and streams its log. Ctrl-C cancels the job there.
  - It brings the results back: a gate's pass into `build/push-gate/passed/<tree>`, so pushing that commit (by the owner or an agent) goes straight through; a regression report into `build/e2e/`, or the release copy's; a performance record appended to `history.jsonl`, to be committed; and each job's log into `build/build-mac/<job>/`.
  - When the build Mac can't be reached, or its macOS or Xcode differ from this Mac's, it says so in one line and runs the same task here. `--there` waits for the build Mac instead; `--here` doesn't try it.
- **A job agent in the build Mac's desktop session.** A process started over SSH runs outside the desktop session, where an app or a test that opens a window may not reach the window server. So a LaunchAgent (`scripts/build-mac/agent.py`, installed by `setup`) runs the queued jobs inside the logged-in session, under `caffeinate -i`: one heavy job at a time to start with, two once measured, and the regression suite and performance runs with the Mac to themselves. A job carries on if the SSH connection drops; `attach` picks its log up again.
- **Lanes.** A clone at `~/build-mac/redlamp`, whose origin is GitHub and which this Mac pushes commits to, and a worktree per lane (gate, test, e2e, release, perf), each keeping its DerivedData between jobs so builds are incremental. Each lane's inputs are cloned from the clone's with `cp -c`, as the gate does.
- **An account for building,** an administrator (Homebrew's installer and the settings need one), logged in automatically, with no signing identities.

## Setting up the build Mac

`scripts/build-mac/setup.sh` does it, run in Terminal on the build Mac; its header has the line that downloads it, and `--help` says what it does. It installs Homebrew and the tools in `scripts/build-mac/Brewfile`, Xcode with its licence, first launch, Metal toolchain and iOS SDK (the workspace builds the Bench app's framework for iOS), PATH for commands run over SSH, the clone at `~/build-mac/redlamp`, mise's tools, the sample raws and the generated workspace, and sets the power, screen lock, update, Remote Login and automatic login settings. Run again, it brings everything up to date. The owner, once:

1. macOS 26.6.2, as on this Mac. On 11 October 2026 the App Store's Xcode is 27.0 and this Mac's is 26.6, so the script installs 26.6 (17F113) with `xcodes`, which asks for an Apple Account with access to Apple's developer downloads; when the App Store's version is this Mac's, it installs from the App Store with `mas`.
2. An administrator account for building, signed in to the App Store, then the script, with `--gate` to finish with a push gate on origin/main. Automatic login needs FileVault off; with it on, after each restart the build Mac serves again once someone logs in, and this Mac runs everything meanwhile.
3. Plugged in, with the lid closed and a display or an HDMI dummy plug. Check that it is still awake and answers SSH an hour later.
4. On this Mac, an SSH key for that account and a `build-mac` host in `~/.ssh/config`, as the script prints when it ends.

## Steps

1. **Workstream canvas.** Done when: it shows this plan's steps.
2. **Tracker row ARC-15 and its issue.** Done when: the row is on main and its issue is open.
3. **The owner sets up the build Mac** (above). Done when: `ssh build-mac true` works from this Mac with the lid closed, an hour after it was last used.
4. **`scripts/build-mac.py` with `setup`, `status`, `gate` and the fallback, and the agent.** Time a gate and a whole suite there against here. Done when: `build-mac.py gate --suite` on origin/main passes there, a push of that commit goes straight through here, and the same command with the build Mac unreachable runs here.
5. **Parity.** The whole suite, the reference tests and the full regression tier at origin/main on both Macs, comparing the results and the numbers of tests run and skipped: a sample raw or a model missing on one Mac skips tests there, and its pass covers less. Done when: they match, or each difference is explained and settled (a tolerance, a skip, or a check that stays on this Mac).
6. **`test`, `e2e` and `release-checks`.** The release checks are every suite and the release tier with focus; the dry run stays here. The release skill gives the owner the line to run. Done when: a release candidate's checks have run on the build Mac and `mise run release` here has accepted its regression report.
7. **Performance.** ARC-09 first; then `build-mac.py perf`, its records as the M4 Max's series, and the card and the README's "Measured on" line moving to it. Done when: a quiet record from the M4 Max is on main and the card draws from it.
8. **Docs.** `docs/build-mac.md` (setting up and using it), `AGENTS.md` (agents ask the owner to run heavy checks there), the performance rule, the release skill and `tools/rl/registry.toml`. Done when: they describe what was built.

## Risks

- Renders that differ between the two GPUs (step 5).
- A pass that covers less: tests skip on a Mac missing a sample raw or a model. `status` and the parity run compare the counts.
- Versions that drift: jobs run here until the build Mac's macOS and Xcode match again.
- Agents' own builds stay on this Mac. Moving them needs agents to reach the build Mac, which their sandbox doesn't allow; the GitHub runner considered above would add it later.
