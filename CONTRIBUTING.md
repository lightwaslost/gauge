# Contributing to Gauge

Thanks for taking a look. Gauge is a small, single-target SwiftUI app, so there
is not much ceremony here.

## Getting set up

You need **macOS 26 or later** and **Xcode 26 / Swift 6.2 or later**.

```bash
git clone https://github.com/lightwaslost/gauge.git
cd gauge
swift run                      # debug build, straight from the terminal
./scripts/build-app.sh         # release → build/Gauge.app (ad-hoc signed)
```

Two things only work from a real `.app` bundle, not from `swift run`: **launch at
login** (`SMAppService`) and **macOS notifications**. If you are touching either,
build the bundle.

There is no test suite. Instead there is a self-test that prints every sampler's
current readings without opening the UI — run it after changing anything under
`Sources/Gauge/Sampling`:

```bash
swift run Gauge --self-test
```

## How the code is laid out

| Path | What lives there |
|---|---|
| `Sources/Gauge/Sampling` | The samplers. Each one reads a system API and returns plain values. |
| `Sources/Gauge/Storage` | SQLite database and the 30-day history store. |
| `Sources/Gauge/Monitor.swift` | The 2-second timer, per-minute snapshots, and alerts. |
| `Sources/Gauge/Views` | All SwiftUI. `Components.swift` holds the shared pieces. |
| `Sources/Gauge/Support` | Preferences, formatting, the self-test, the demo driver. |

`Monitor` is the only thing that owns a timer. Samplers are pure: give them a
call, get a reading back. Keep it that way — it is what makes the self-test
useful.

## House rules

- **Gauge makes no network requests.** This is the whole promise of the app. A
  pull request that adds one will not be merged, including analytics, crash
  reporting, update checks and remote config.
- **Match the surrounding code.** Same naming, same comment density. Comments
  explain *why*, not *what*.
- **No new dependencies** without a good reason. The app has zero today, and
  that is a feature.
- Readings you cannot get should say so. Show "unavailable" rather than
  guessing or printing a zero — see how GPU utilisation is handled.
- User-facing strings are sentences, in plain language. "Memory grows by",
  not "Mem. threshold exceeded".

## Pull requests

Open an issue first for anything large, so you do not build something that gets
turned down. For small fixes, just send the PR.

Before you push: `swift build` cleanly, and run the app to check the screen you
touched actually looks right.

By contributing, you agree that your work is licensed under the
[MIT licence](LICENSE).
