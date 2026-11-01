# Shared resource locks

Several sessions on one machine often want the same scarce thing at once: the iOS simulator, a
Rails test database, a GPU, a port-bound dev server. `maple-runner lock` makes them take turns.

```sh
maple-runner lock <name> [--slots N] [--timeout SECS] -- <command…>
maple-runner locks
```

`lock` asks the running runner for a slot of the lock `<name>`, waits in line if every slot is
taken, runs the command once it has one, and exits with the command's exit code. The slot is freed
when the command ends, or when the wrapper dies for any reason (even `kill -9`): it's held by an
open connection to the runner's hook socket, so a crashed process can't leak it. Waiters are served
first in, first out.

Names are free-form; everything that locks the same name on the same machine takes turns. A lock
exists only while someone holds or waits for it.

## Wrapping a command

Inside a factory session, `$MAPLE_RUNNER` is the runner's binary, so a repo script doesn't need
`maple-runner` on `PATH`. Fall back to running the command directly so the script still works
anywhere else:

```sh
runner=${MAPLE_RUNNER:-$(command -v maple-runner || true)}
if [ -n "$runner" ]; then
  exec "$runner" lock ios-simulator -- xcodebuild test -scheme App -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
fi
exec xcodebuild test -scheme App -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

`maple-runner lock` also runs the command (unlocked, with a one-line note on stderr) when no runner
is reachable, so the fallback is only needed where `maple-runner` isn't installed at all.

To lock a whole script, have it run itself again under the lock, as `apps/ios/scripts/run-ios.sh`
does:

```sh
if [ -z "${MAPLE_LOCKED:-}" ]; then
  runner=${MAPLE_RUNNER:-$(command -v maple-runner || true)}
  if [ -n "$runner" ] && "$runner" lock --help >/dev/null 2>&1; then
    export MAPLE_LOCKED=1
    exec "$runner" lock ios-simulator -- "$(realpath "$0")" "$@"
  fi
fi
```

A Rails app sharing one test database between worktrees:

```sh
"${MAPLE_RUNNER:-maple-runner}" lock rails-test-db -- bin/rails test
```

Your own terminal takes part too: a `maple-runner lock` run outside any session waits its turn like
the agents do, and shows to them as "your terminal".

## Slots

A lock has one slot unless something says otherwise. `--slots N` asks for N (the largest any current
requester asked for wins). A machine can set its own count in `~/.config/maple/locks.toml`, which
beats `--slots` and is read again on every request:

```toml
# This Mac has the memory for two simulators at once.
ios-simulator = 2
rails-test-db = 1
```

## On the task

While a session waits, its task shows the wait as its live line in the Mac app, on iPhone and on the
web, for example:

> Waiting for ios-simulator · 1 ahead (MF-327 has it)

"1 ahead" is its place in line. Once it gets the slot the line goes back to what the agent was
doing. The wrapper prints the same line to stderr, so the agent sees why its command is waiting.

`maple-runner locks` shows every lock with its holders and waiters:

```
ios-simulator (1 of 1 slots held, 1 waiting)
  holds:   MF-327 pid 4121, 84s
  waits 1: MF-330 pid 5532, 12s
```

`--timeout SECS` gives up (exit 1) after waiting that long, without running the command.
