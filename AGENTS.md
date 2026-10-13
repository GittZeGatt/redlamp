# Rules for agents working on Redlamp

Redlamp is a macOS raw editor in Swift and Metal (`README.md`). These rules apply to any agent working in this repository, and especially to domain agents working in parallel during an agent wave (`docs/plans/2026-10-03-wave-1-plan.md`).

## Environment

- **Tools sit behind mise.** Run `mise exec -- tuist generate --no-open` after adding or removing source files, and `mise exec -- swiftformat <files>` on every Swift file you change (CI lints the whole tree).
- **Build and test** with your own build directory, inside your checkout (`build/` is gitignored, so it goes with the worktree):
  `xcodebuild test -workspace Redlamp.xcworkspace -scheme <Scheme> -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData-<your-key> -only-testing:<Target>/<Suite>`.
  Schemes: `RedlampEngine`, `RedlampEngineAPI`, `RedlampKernels`, `RedlampMasking`, `RedlampServices`, `RedlampDocument`, `RedlampRecipes`, `RedlampUI`, `Redlamp` (app), `redlamp` (CLI). Run targeted tests while working and your scheme's full suite once at the end; never run several full builds at once.
- **`~/src` lives on an external SSD** (`/Volumes/SSD/README.md`). A test that fails with "Operation not permitted" on files under `~/src` means Xcode or `xctest` has lost Full Disk Access; say so in your report rather than working around it.
- **Tests run with Metal's validation layer** (`MTL_DEBUG_LAYER=1`, set on every test target): a test that aborts with a `validate…` message has found a dispatch or binding the app would crash on in Debug; fix the dispatch, don't turn validation off.
- **Swift Testing:** `xcodebuild` prints XCTest's "Executed 0 tests" plus one "Test run with N tests … passed" line per bundle. Read the Swift Testing lines.
- **Pushing to `main` runs the push gate** (`.githooks/pre-push`, `scripts/push-gate.py`) on the commit being pushed, in a worktree of its own (`../darkroom-push-gate`) that holds only what's committed: CI's quick checks, and when code changed, SwiftFormat, a build of everything with its tests, and the reference tests (golden renders, process references, recorded reports, the sidecar schema, scenario coverage): a few minutes (6½ at a load average of 70, against 40 or more for the whole suite). A failure stops the push. Don't skip it with `--no-verify`: fix what fails and push again, or, if `origin/main` fails the same way, say so. The rest of the suite runs on CI, so still run your scheme's suite as above, and `mise run gate -- --suite` before pushing work that spans packages, such as a wave's merge. `mise run gate` checks a commit ahead of its push, which then goes straight through.
- **The build Mac** (`scripts/build-mac.py`, ARC-15), the owner's M4 Max, takes heavy runs off this Mac, and an agent's shell reaches it through the sandbox relay (`scripts/sandbox-relay.py`, which the owner installs; its `status` says whether the build Mac answers through it). `scripts/build-mac.py gate [<commit>] [--suite]` runs the push gate there and keeps its pass here, so pushing that commit goes straight through, and `e2e` runs the regression suite there; when the build Mac doesn't answer, the same command runs here. Jobs there run one at a time: `build-mac.py status` lists what's running and queued, `--here` runs a check on this Mac instead, and a long job can be started with `--detach` and followed with `attach` in a background shell. Until ARC-15's parity run, a failure there that doesn't happen here may come from its GPU or macOS 27 rather than your change: say so in your report. Use it for builds, tests and their results, not to reach what the sandbox refuses.
- **CI's runner is much smaller than this Mac:** GitHub's `macos-26-arm64`, documented as 3 cores and 7 GB of memory, has a screen that leaves a window at most 700 points of height, and compiles about 2.2 times slower. A test that passes here, and the push gate with it, can still fail there. Don't count on an on-screen window growing taller than that (macOS keeps it within the screen; resize it ordered out), on purgeable textures surviving a test that opens several full-size photos, or on a timing with a tight limit. The Debug build fails a function body that takes over 1,500 ms to type-check here and 3,000 ms there (DEC-70), and an expression over 1,000 ms here and 3,000 ms there (DEC-65); the first function body in a compile job to use `NSMenuItem` pays AppKit's import of it, about 0.7 s here and 1.7 s there.
- **A fresh worktree needs the gitignored build inputs.** From the worktree root, with `MAIN=/Users/pedrogomes/src/darkroom`, clone them (never symlink: scripts in the worktree would write into the main checkout):

  ```bash
  mkdir -p tests/fixtures vendor Tuist
  cp -cR "$MAIN/tests/fixtures/raw" tests/fixtures/
  [ -d "$MAIN/tests/fixtures/cameras" ] && cp -cR "$MAIN/tests/fixtures/cameras" tests/fixtures/
  [ -d "$MAIN/tests/fixtures/shoots" ] && cp -cR "$MAIN/tests/fixtures/shoots" tests/fixtures/
  cp -cR "$MAIN/vendor/build" "$MAIN/vendor/cache" vendor/
  cp -cR "$MAIN/Tuist/.build" Tuist/
  mise exec -- tuist generate --no-open
  ```

- **Remove your worktree when your work is done.** Each worktree has its own build folder, and they all share the SSD, which filled up on 13 October 2026 with 75 of them checked out. Once what you need is committed to your branch, and pushed when your work goes to `main`, remove the worktree from the main checkout with `git worktree remove <path>`, which deletes its build folder with it. The branch keeps your commits, and `git worktree add <path> <branch>` brings the worktree back if you're asked for more. `git worktree remove` refuses while anything is uncommitted: commit what you need, and don't `--force` it over changes you haven't read. Delete the scratch you made outside the worktree too: copies of fixtures, homes and disk images under `/Volumes/SSD/redlamp-tmp`, recordings and renders once they're delivered, and what you left in `/tmp` and `$TMPDIR`. The worktrees that stay are the main checkout, the push gate's (`../darkroom-push-gate`) and the release room's (`~/src/redlamp-release`).
- **Sandbox:** the npm and yarn registries are unreachable; don't add packages of any kind (Swift packages included). PyPI works for research scripts. Never print secrets (the Hugging Face token in `~/.cache/huggingface/token` included).
- **Headless Chrome**, if you need it, starts only with `--no-sandbox --disable-gpu-sandbox --use-angle=swiftshader --enable-unsafe-swiftshader` and a throwaway `--user-data-dir`.

## Working in parallel

- **Stay inside the paths you own** (the plan's table). Everything else is read-only, including `EditRecipe.currentProcessVersion`, `docs/research/research-tracker.md`, `README.md`, `docs/lightroom-comparison.md`, this file, the plan, `Project.swift`, `Workspace.swift` and `.github/`. Ask for changes in your final report, and name the README roadmap items and Lightroom comparison rows your work changes, so the orchestrator can bring them into step on merge (`.cursor/rules/roadmap-and-comparison.mdc`). Don't record performance runs during a wave (parallel builds make them noisy); name performance-sensitive changes instead, and the orchestrator records after merging (`.cursor/rules/performance.mdc`).
- **Bugs that produce wrong pixels** (NaN, black or out-of-range values) are fixed in every process version: no edit relies on them. A reference that recorded such a pixel is re-recorded in the same change, and the commit says which pixels changed and that nothing else did.
- **No agent changes how an existing edit renders.** A rendering change needs a new process version, and that is the orchestrator's call. The process-stability gate (`ProcessStabilityTests`) catches it; a new version records its references with `TEST_RUNNER_REDLAMP_RECORD_PROCESS_GOLDEN=1`, which writes only missing ones, and raises the process version's maximum in `docs/recipes/sidecar-format.schema.json` and its table in `sidecar-format.md` (`SidecarSchemaTests` checks both).
- **Off limits:** removal (RM-*), the audit fixes (AUD-*), noise (DN-*), `video/` and `web/`; other sessions are working there.
- **Commit to your own branch** in small, described commits. Never push, merge or rebase onto `main`. A bug's agent, started from the reports room's Fix it, is the exception: it pushes its own fix to main through the push gate (`.cursor/skills/redlamp-reports/bug-agent.md`).
- **Commit messages** are short and name the tracker row and its issue: `LCP lens profiles: parse and match (LNS-04, #82)`.

## Working within a budget

Tokens are a budget: agent work is moving to fixed subscriptions with no on-demand spending, and [docs/working-with-agents.md](docs/working-with-agents.md) explains what it costs. Every step re-sends the whole conversation, and after about five idle minutes the provider's cache expires and the next step pays 25 times as much to send it.

- **Don't wait inside a long conversation.** Run the push gate, full suites and anything else that takes minutes in the background, and check on them at intervals under four minutes (`block_until_ms` of 240000 or less in Cursor), or end the turn and say what's still running.
- **One task per chat.** When the task is done, leave the handover in the tracker, the workstream canvas or the plan, and suggest a new chat for the next task rather than carrying on in this one.
- **Say when a chat has grown long, without being asked.** Once a conversation is past about 200K tokens (often after 50 or so tool calls), or a second task starts in it, tell the owner before going on, and give the handover brief for a new chat: where things stand, where that's recorded (the tracker row, the canvas, the plan), what's next, and a prompt to start it with.
- **Read what you need.** Search the long files (the README, the tracker) before reading them, and don't read a file again unless it has changed.
- **Subagents:** at most three at a time, each with a brief complete enough that it doesn't need the parent's context.

## Conventions

- Write code that reads like the code around it: its naming, comment density and idiom. Comments state constraints the code can't show; not what the next line does, nor why your change is right.
- Tests sit with their package (`packages/<Package>/Tests`) and use Swift Testing (`@Test`, `#expect`, backticked names that read as sentences).
- A feature lands with its regression scenario (`packages/RedlampAutomation/Sources/Scenarios/`), worked through the user's own input path: `RedlampAutomationTests` fail when an action, parameter, panel, tool, mask kind or Report a Bug feature has no scenario or exemption. After UI work, run `mise run e2e` (the smoke tier); it runs in the background in a home of its own.
- No focus rings, on any screen: end the root view of every `NSHostingView`, `NSHostingController` and scene in `.focusEffectDisabled()`, and leave AppKit's rings to `FocusRings`, which removes them in every window. `scripts/check-focus-rings.py` checks both (`.cursor/rules/focus-rings.mdc`).
- Docs are plain and precise, in complete sentences, with no superlatives.
- Licences: implement from published specifications and papers. Never copy code from GPL projects, and never ship or convert Adobe's files.
- Raw files: [`docs/raw-pipeline.md`](docs/raw-pipeline.md) describes how Redlamp decodes and develops them, from LibRaw to the demosaic and camera colour, and how to add a camera, update LibRaw or add a decoder. Read it before changing that code, and update it in the same change.

## Reporting during a wave

The orchestrator's tracker canvas has one progress line per agent between `// AGENT_PROGRESS:BEGIN` and `// AGENT_PROGRESS:END`. Update only your own line, as your brief describes, when you start, after each milestone, when blocked and at the end.
