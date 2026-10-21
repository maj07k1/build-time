# Build Time

A free, open-source macOS menu bar app that tracks how long you wait for builds. It reads Xcode's build logs, SwiftPM's build databases and npm's logs, then tells you things like "you waited 3h 40m for builds this week" and which targets are slowest.

> **Unofficial.** Build Time is a community project. It isn't affiliated with, endorsed by or supported by Apple, npm or GitHub.

## Features

- **Waiting time in the menu bar.** This week's or today's total, next to a hammer.
- **Honest totals.** Builds that run at the same time count once, so the headline is time you actually spent waiting, not every build's duration added up.
- **Today, this week, this month.** Builds per hour or day, split by tool, compared with the same point in the previous period.
- **Slowest targets.** Xcode targets, Swift modules and npm scripts ranked by average time per build, with how often each was built.
- **By project and recent builds.** Where the time goes, with failed builds marked.

## Where the numbers come from

| Tool | Read from | What's in it |
| --- | --- | --- |
| Xcode | `~/Library/Developer/Xcode/DerivedData/*/Logs/Build/` (or your custom DerivedData location) | `LogStoreManifest.plist` gives each build's start, end and result. Each `.xcactivitylog` gives per-target times. |
| SwiftPM | `<package>/.build/build.db` | llbuild's database: when each compile and link step last ran. One build is one `swift build` or `swift test`. |
| npm | `~/.npm/_logs/*-debug-0.log` | The start time is in the file name and the end is when the log was last written. Only `npm run` scripts that build, type-check or test count. Dev servers, watchers, installs and `npx` don't. |

npm keeps only its last 10 logs, and SwiftPM keeps only the latest run of each step, so the app copies each build into its own history as soon as it appears. That means **history starts when you first open the app** (plus whatever was still on disk), and builds are only recorded while it's running. Turn on **Launch at login** in Settings.

Swift packages are found by searching your Desktop, Documents, Developer, Projects and similar folders up to four levels deep. You can change the folders in Settings.

SwiftPM times cover building, not package resolution or running the tests.

## Privacy

- **Nothing leaves your Mac.** The app has no network code, no analytics and no servers.
- **Build logs are only read, never modified.**
- History is stored in `~/Library/Application Support/BuildTime/history.json`.

## Install

Requires macOS 14 Sonoma or later, on Apple Silicon or Intel.

1. Download the latest `Build-Time-<version>.zip` from the Releases page and unzip it.
2. Move **Build Time.app** to your Applications folder.
3. The first time you open it, macOS will warn that the app is from an unidentified developer. Releases aren't notarized because that needs a paid Apple Developer account. To allow it:
   - macOS 15 and later: try to open the app once, then go to **System Settings → Privacy & Security** and click **Open Anyway**.
   - macOS 14: right-click the app, choose **Open**, then confirm.

If you'd rather not trust a downloaded binary, building from source takes about a minute.

## Build from source

You need the Xcode Command Line Tools (`xcode-select --install`). Xcode itself isn't required.

```bash
git clone <this repository>
cd build-time
./build.sh --install
```

`build.sh` produces a universal app in `build/`. Run it with `--zip` to also create a release archive. The script's header lists optional settings: `VERSION`, `SOURCE_URL`, `TIP_JAR_URL` and `SIGN_IDENTITY`.

### Development

```bash
swift test
```

```bash
BUILD_TIME_SNAPSHOT=/tmp/build-time-shots swift run
```

The snapshot command reads your real build logs into a throwaway history (your saved history is left alone), renders each period and the settings to PNG, prints this week's slowest targets, then exits.

Code layout, all in `Sources/BuildTime`:

| File | What's in it |
| --- | --- |
| `XcodeLogs.swift` | DerivedData manifest, the SLF `.xcactivitylog` format, gzip |
| `SwiftPMLogs.swift` | `build.db` reader, package discovery |
| `NpmLogs.swift` | npm debug logs and which scripts count |
| `Scanner.swift` | Polling the sources and keeping the history |
| `Stats.swift` | Waiting time, per-target and per-project totals |
| `AppModel.swift`, `Views.swift` | App state and UI |

## License

[MIT](LICENSE)
