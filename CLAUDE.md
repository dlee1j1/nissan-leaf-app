# nissan-leaf-app

Flutter app that captures Nissan Leaf metrics over BLE from an OBD-II dongle.

## Where things go

- **CLAUDE.md** (this file) — build conventions, environment gotchas, and
  architectural decisions with their reasoning. Read every session, so keep
  it short. Add something here only when it would change how the next
  session works.
- **README.md** — what the project is and how to get started. Introduction,
  not reasoning.
- **GitHub issues** — task detail, scope, and acceptance criteria. Also
  where you report back: comment on the issue with what you did, what you
  couldn't verify, and anything you skipped or noticed along the way.

Don't file new GitHub issues unprompted. If you notice something outside
the current scope, note it in the issue comment and I'll decide whether it
becomes its own issue.

## Build

Always use `make` targets from the repo root on the host.
Avoid calling `docker` or `docker-compose` directly if at all possible.

The Makefile has a catch-all rule that detects whether it's running inside
the container. From the host, `make <target>` starts the container and
re-invokes itself inside it. So `make apk`, `make test`, `make analyze`
all work directly from the Mac.

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

## Decisions

**The background service dies because Android kills it, not because it
crashes.** Random death after hours, surviving when freshly started, is
resource reclamation. Don't add watchdogs or restart logic — that's a
treadmill against every OEM battery manager.

**Instead, only run when it matters.** Metrics are only interesting while
driving, and the OBD dongle appears on BLE when the car powers on. A
manifest-declared receiver on `ACTION_ACL_CONNECTED` starts the foreground
service; disconnect stops it. Nothing running means nothing to kill.

**No boot receiver.** Manifest-declared receivers are registered from the
package, so they survive reboots without a live process. Revisit only if
the heartbeat log shows missed drives.

**No persisted "service enabled" flag.** The dongle's presence is the
source of truth; a stored flag can only disagree with reality.

**Permission checks belong in the receiver path**, not just at app launch.
Permissions can be revoked between drives.

