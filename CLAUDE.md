# nissan-leaf-app

Flutter app that captures Nissan Leaf metrics over BLE from an OBD-II dongle.

## Where things go

- **CLAUDE.md** (this file) — build conventions and environment gotchas.
  Read every session, so keep it short. Add something here only when it
  would change how the next session works. Subsystem design decisions live
  with that subsystem's docs (e.g. `nissan_leaf_app/docs/`), not here.
- **README.md** — what the project is and how to get started. Introduction,
  not reasoning.
- **GitHub issues** — task detail, scope, and acceptance criteria. Also
  where you report back: comment on the issue with what you did, what you
  couldn't verify, and anything you skipped or noticed along the way.

Don't file new GitHub issues unprompted. If you notice something outside
the current scope, note it in the issue comment and I'll decide whether it
becomes its own issue.

## Conventions

- **Write modules testable without a harness.** Push platform/plugin calls
  to a thin edge — a wrapper class, an injected interface, a
  `@visibleForTesting` setter or reset hook — and keep the decision logic
  in a pure unit. Examples: `ForegroundTaskWrapper` around the
  `FlutterForegroundTask` statics; `ObdConnectionPolicy` (no `android.*`
  imports) split out of `ObdConnectionReceiver`; `setOrchestratorForTesting`
  / `resetForTesting`; platform-interface fakes in tests. Plain `flutter
  test` and plain-JVM JUnit only — no Robolectric, no emulator.
- **Docs and tests land with the code.** A behaviour change updates its
  `nissan_leaf_app/docs/` page and its tests in the same PR, not a
  follow-up.

## Build

Always use `make` targets from the repo root on the host.
Avoid calling `docker` or `docker-compose` directly if you can use make. Reason: keep the Makefile relevant. But if you have to look inside, running `docker` or `docker-compose` is valid.   

The Makefile has a catch-all rule that detects whether it's running inside
the container. From the host, `make <target>` starts the container and
re-invokes itself inside it. So `make apk`, `make test`, `make analyze`
all work directly from the Mac.

Commit locally as necessary, in reasonable chunks. Don't push, open a PR,
or merge until Dennis has reviewed the changes and explicitly says to go
ahead — he does the code review before anything reaches the repo. Once he
signs off on a batch of changes, handle push/PR/merge for it yourself
without asking again.

Flutter, the Android SDK, and Gradle exist only inside the container.

### Expectations

- First build on cold volumes is slow (minutes). Gradle cache is a named
  volume; later builds are fast.
- Flutter ships x64-only engine artifacts, so the container needs amd64
  package support to run `gen_snapshot` under Rosetta on Apple Silicon.
- The Flutter version is pinned in the Makefile's `setup` target.
  Tracking `stable` is what silently broke the build; don't unpin it.
- USB passthrough doesn't work under Colima on macOS. Build the APK in
  the container, then `adb install` from the host.



<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:1105d646 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->
