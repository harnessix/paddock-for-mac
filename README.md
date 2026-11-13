# paddock for Mac

paddock for Mac starts your coding agents and your Mac apps in sandboxes, and shows each one in its own room. Your computer stays yours: an agent works in its room and cannot reach your keys or your other projects, and it asks you before each step unless you let it work on its own.

- Agents: Codex, Claude Code, Gemini CLI, OpenClaw and the other command-line agents that paddock knows. Each one runs in a terminal pane in the app.
- Mac apps: each app runs in its own small macOS virtual machine, and its windows show on your desktop. You decide which servers the app can reach and which folders it can see.
- Questions: when an agent or an app asks for something, a card shows it, and you answer with one click.

## What you need

- A Mac with Apple silicon (M1 or newer) and macOS 14 or newer
- The paddock command, 0.2.3 or newer:

  ```sh
  brew tap harnessix/paddock
  brew install paddock
  ```

- For Mac apps only: about 40 GB of free space for the base image. Each app shares the base image and adds only its own changes.

## Install

Download `paddock-for-Mac.zip` from the [latest release](https://github.com/harnessix/paddock-for-mac/releases/latest), unzip it, and move "paddock for Mac" to your Applications folder. This build has no Apple notarization yet: the first time, open it with Control-click and Open.

## Build from source

paddock for Mac speaks the language of your Mac: English, Simplified Chinese, Traditional Chinese, Japanese, Korean, Spanish, French, German, Brazilian Portuguese, Russian and Italian.

You need macOS 14 or newer, Xcode 15.3 or newer, and XcodeGen (`brew install xcodegen`). Run each command from this folder.

Generate the Xcode project:

```sh
xcodegen generate
```

Run the PaddockKit tests:

```sh
(cd PaddockKit && swift test)
```

Build the app and run the unit and UI tests:

```sh
xcodebuild -project PaddockLauncher.xcodeproj -scheme PaddockLauncher -destination 'platform=macOS' test
```

Check the string catalog:

```sh
python3 Scripts/strings.py --check
```

Do all the checks above with warnings as errors:

```sh
Scripts/check-build.sh
```

Archive, sign and check the release build:

```sh
NOTARY_PROFILE=paddock Scripts/check-build.sh --release "Developer ID Application: NAME (TEAMID)"
```

Run the checks against the real paddock:

```sh
Scripts/nightly-real.sh APP [SHIM_BUNDLE_ID]
```

## The paddock check

paddock for Mac runs two commands on the paddock that it finds, in this order:

1. `paddock --version`. The version must be 0.2.2 or newer, with major version 0.
2. `paddock --launcher-protocol` on the same binary. The answer must be one JSON object with `"protocol":"paddock.mac-launcher/v1"` and every feature in `LauncherProtocol.required`.

Each command has a time limit of 15 seconds and an output limit of 16 KiB. Past a limit, or on Check Again, paddock for Mac kills the child process. The app stays unusable until both checks pass. The released paddock 0.2.2 does not know `--launcher-protocol`, so paddock for Mac asks you to update paddock.

## The real paddock JSON

`Fixtures/real-0.2.2` holds the output of paddock 0.2.2 on a Mac for every command that the launcher runs. The agent commands `list`, `recent`, `ps` and `board` are among them. URLs, emails and IDs are replaced. `ContractTests` decodes each file with the code path that the launcher uses for its command, and checks the values. A new file in that folder needs a case in `ContractTests`.

The checklist of the base image step ("This Mac") shows each entry of the `checks` list of `paddock doctor --json`, with paddock's level and line. paddock exits 1 when a check fails and still prints the whole report. `paddock doctor --json` and the add precheck (`paddock app add PATH --dry-run --json`) have a time limit of 20 seconds. Past it, paddock for Mac kills the child process and shows "paddock did not answer in 20 seconds." with Check Again.

## The welcome window

The welcome window leads to the first agent at work. It has three steps:

1. Welcome. The room with the character at work, the title "Your computer stays yours" and three points: you use your agent as usual and it asks you before each step, or works on its own when you choose that; each agent lives in its own room and cannot reach your keys or your other projects; in a git project the agent can work on a copy, and you decide what goes back. A last line says that your Mac apps can get rooms too.
2. Check this Mac. The paddock that was found, with its version and the launcher protocol. The agents of `paddock list --json`, each with its character. An agent that paddock found shows its path. An agent that paddock knows but did not find shows its install command (`AgentInstall`), when the launcher knows one; paddock's list has no install hint yet. "Look again" asks the shell and paddock again. The free space of the disk. This step does not run `paddock doctor`.
3. Start your first agent. The fields of New Agent, inline: the agent, the project folder, how the agent works and the options. "Ask me before each step" is the first choice here and it is selected. "Full auto in the sandbox" is the second, with no recommendation. Start opens the agent pane in the main window. "Skip for now" opens the main window.

`AgentMode.initial` is the mode of a start before the user chose one. It is the one place that names the default mode. It is manual: the agent asks you before each step. Full auto is an opt-in. The New Agent sheet lists the modes in the same order as step 3.

The launcher saves the mode of the last start of each agent in its settings, under `agentMode.AGENT` (`AgentModeMemory`). The sheet shows the mode of the chosen agent, until you choose a mode in the sheet. An older launcher saved one mode for all agents under `agentMode`. This launcher reads that key and does not write it. So if you ran agents in full auto before, each agent stays in full auto until you choose manual for it. A new user has no key, and each agent starts in manual. "Reset paddock for Mac settings" removes these keys.

A run in full auto has the small "auto" tag on its room and in its detail, and its spoken line says "works on its own". A run in manual mode has no tag. Its detail says "Asks before each step". The mode comes from `approvals` in `paddock ps --json`, or from the pane for a run that this launcher started. If neither says it, the room shows no mode.

The window shows when paddock is missing or cannot be used. It also shows once on a Mac with no app and no base image, until Start or "Skip for now" (`LauncherStore.needsOnboarding`, the `welcomeDone` setting). No step is about the base image.

The base image is a step of the Apps section. Add App goes to the Base image page first while no base image is there. The page says what the base image is, its size and its time, shows the checks of `paddock doctor` and the free space, and has Build. The build has Pause, Resume and Cancel. A window with no app opens on a build that waits or failed.

Add App keeps the app that you chose (`LauncherStore.pendingAdd`): a drop, an app from the review sheet, or the Build… button of a refused review. The app has its room at the top of the Base image page and a row under the apps in the sidebar, both with what it waits for. When the build ends, paddock for Mac runs paddock's review and the add itself, with paddock's name and memory, and the window selects the new app. A refused add stays with the app as an inline error, with Try Again, Review… and Do Not Add. When Add App had no app yet, the page offers Add App after the build.

The review sheet does not stop at a missing base image. When paddock refuses the app only for the base image, and the launcher has no ready base image, the sheet hands the app over and the window goes on to the Base image page (`AddHandoff`, `UIRouter.waitForBaseImage`).

A window with no app and no agent run leads with New Agent; Add App is the second choice. The menu of the status item starts with the agents. Its Apps part, with the base image line, shows once there is an app or a base image.

A debug build shows step N of the welcome window in a snapshot when you set `PADDOCK_LAUNCHER_SNAPSHOT_WELCOME=N` together with `PADDOCK_LAUNCHER_SNAPSHOT=DIR`. `PADDOCK_LAUNCHER_WELCOMED=1` starts a debug build past the welcome, and `0` shows it again.

## The PATH of your shell

An app that starts from Finder or the Dock gets the PATH `/usr/bin:/bin:/usr/sbin:/sbin`. paddock looks for the agents in the folders of PATH, so with that PATH it finds none. The agents are in folders that your shell adds, such as `/opt/homebrew/bin`, `~/.local/bin` and `~/.grok/bin`.

So paddock for Mac asks your login shell for its environment, once at each launch (`ShellEnvironment`). It runs `$SHELL -l -i -c` with a command that prints a marker, the output of `/usr/bin/env -0` and the marker again. If `SHELL` is not set, it runs `/bin/zsh`. The shell runs in a session of its own, with no input. The launcher reads only what is between the two markers, so a greeting of your start files does no harm. The time limit is 5 seconds. Past it, the launcher kills the process group of the shell.

Check Again and "Look again" ask the shell again. So does a new shell in Settings > Advanced > Shell; an empty field means your login shell.

Every `paddock` call and every agent pane gets PATH and a named set of variables from that answer (`ChildEnvironment`), not the whole environment of the shell:

- `HOME`, `USER`, `LOGNAME`, `SHELL`, `TMPDIR`, `LANG`, `LC_ALL`, `LC_CTYPE`, `LC_MESSAGES`, the four `XDG_*_HOME` folders and `SSH_AUTH_SOCK`.
- The proxy variables (`HTTPS_PROXY`, `NO_PROXY` and the others, in both spellings).
- The variables that paddock's profiles name for the agents in `env_pass`, such as `ANTHROPIC_API_KEY` and `OPENAI_API_KEY`. `paddock list --json` does not give these names, so the list is in `ChildEnvironment.agents`, from the profiles of paddock 0.2.3. When a profile of paddock gets a new name, add it there.
- paddock's own variables: each name that starts with `PADDOCK_`.

A variable that the shell does not have comes from the environment of the launcher itself.

If the shell does not start, does not answer in time or gives no PATH, the PATH is the usual install folders (`FallbackPath`): `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.bun/bin`, `~/.npm-global/bin`, `~/.cargo/bin`, `~/.NAME/bin` for each agent that paddock knows, and `~/.kimi-code/bin`. The PATH of the launcher itself comes after them. Check this Mac then shows the line "Your shell did not answer, so paddock for Mac uses the usual folders."

The tests use small scripts as the shell, never your shell. A debug build runs the script of `PADDOCK_LAUNCHER_SHELL` in place of the shell, with the time limit of `PADDOCK_LAUNCHER_SHELL_SECONDS`. A UI test without that variable asks no shell.

## The messages

Every message comes from paddock for Mac itself, with its icon.

- Notifications. `NoticePoster` in `App/AppDelegate.swift` is the one place that posts them, with `UNUserNotificationCenter`. Nothing in the launcher runs `osascript`. paddock's CLI posts its own notifications through `osascript`, which shows the Script Editor icon; the launcher does not rely on them.
- Notices. A `Notice` (PaddockKit) is one message: a title, a text, and the place a click goes to. `NoticeBook` makes notices from `paddock events --follow --json`: an app session that ends in `error` or is `blocked`, a base image build that failed or is done, questions that paddock paused, and a line of the kind `notice` (also `notify`, `notification`), shown in paddock's words. The event stream of core `e1c120b` has no such kind yet; the reader takes `title` or `summary`, and `text`, `body`, `message` or `detail`, and for the target `app` and `home`, `sandbox` or `run`, or `about`. The open questions and the agent rooms make their notices from their own lists, after the time of the setting.
- The window. A notice of the event stream also shows as a line at the bottom of the main window, with Show and Dismiss (`NoticeBar`). While the window is in front, the system only lists that notice; every other notice shows its banner.
- A click. The `userInfo` of a notification holds the target and the card (`NoticeRoute`). A click opens the main window there (`NoticeOpener`). The notification of a waiting request opens the Questions list on the card of that request, marked "From your notification".
- Errors. An error shows in the screen where it happened: one plain sentence with the next step (`InlineProblem`, `PlainError`), and the action that fixes it. A line of paddock's CLI is never the message. It is under the "Details" disclosure. The refusal texts and check lines of paddock's JSON reports follow the rule of "One language per interface" below.
- Alerts. `AppAlert.make` makes every `NSAlert`, with the icon of the app. An alert is for what blocks the app: a paddock that cannot be used, the question before a quit with agents, and the move to the Applications folder.

## One language per interface

The interface is in one language: English or Simplified Chinese. No line mixes the two.

- Every key of the catalog has a text in each language. `Scripts/strings.py --check` fails on a key with no Chinese text. If a Chinese text takes other values than its key, the check fails too.
- A text can take a text as a value: `UIText("Used %@", Format.age(…))`. The app localizes the inner text too. Do not fill in `.english` of a text.
- A translation takes its values in order with `%@`. If its language needs another order, it takes them by place: `%1$@`, `%2$@` (`UIText.fill`).
- A line that paddock wrote is `UIText.cli(line, else: fallback)`. In English, the line shows as it is. In Chinese, a line that `CLIWords` knows shows its catalog text, with its values. An unknown line shows the fallback sentence of its place, and the line is under "Details" (`DetailedText`).
- If paddock gets a new line, add it to `CLIWords.lines` with `%@` for each value. Then translate it in the catalog.
- `TextTests` reads the real catalog. It checks that the lines of the app have no English word in Chinese.

## The screens

Each screen has a hero: the room art, the name, the state and one prominent action. Grouped facts follow. The options that you seldom need are behind "Advanced".

- An app. `HeroAction` gives the prominent action: Start, Resume or Open. If the base image is missing, the action is "Build the Base Image…" and it opens the Base image page. While the image builds, the action is "Show the Build". The Overview has the groups "This app", "Storage" and "Network". Before the first start, Storage says "Nothing stored yet. The first start prepares the app." (`StorageSummary`). No row repeats the state. No row shows a zero. "Clear Saved State…" and "Remove App…" are behind "Advanced".
- The base image. The build shows one progress bar (`BuildProgress.overallFraction`), what the build does now, the time, and the four steps as a checklist. The folder and the restore image are behind "Advanced". So is "Remove Base Image…".
- The window. The sidebar starts with the paddock icon and name. "Add App…" has its words. "New Agent" shows its title in the toolbar. The List / Rooms switch shows only on a page that has rooms (`ToolbarRule`). The window title is the page (`WindowTitle`).
- Requests. An agent request shows its age ("Asked 3 d ago"). A request is expired after one day, or after its time limit (`RequestAge`). The Questions page then shows one line and "Clear Expired", which answers No to each expired request.
- Empty pages. Each has the room art, one sentence and its main action. If paddock listed its agents and found none on this Mac, the Agents page says so and offers "Look Again" (`AgentsEmpty`).

## The next screen

Each action ends on a screen that shows its result.

| Action | Next screen |
| --- | --- |
| Start an agent | Its pane. In the Rooms layout the room opens too (`LauncherStore.openRoom`). |
| Add an app | Its detail. Without a base image: the Base image page with the app's room. |
| Remove an app | The next app in the list, else the one before, else the empty state (`LauncherStore.neighbor`). |
| Stop | The room says "Stopped". An agent run that ends by itself says "Ended". |
| A failure | The inline error, in the same place. The sheet of a failed Remove stays open. |

No selection leaves the detail empty. With no app selected the detail is the home page: what to do next (`NextStep`), New Agent and Add App. A run that paddock no longer lists has New Agent and Show All Agents. The room of an app that waits for the base image shows the build.

## The files of paddock core

This folder builds and tests without the rest of paddock core. `Fixtures/core` holds copies of core fixtures. `core.pin` names the core version and commit that they come from.

To move the pin:

1. Copy `tests/fixtures/launcher/*.jsonl` of the new core commit into `Fixtures/core/launcher`.
2. Copy `tests/fixtures/launcher-protocol/*.json` and `*.err` into `Fixtures/core/launcher-protocol`.
3. Change `version` and `commit` in `core.pin`.
4. Run the PaddockKit tests.

## The agents

The sidebar has an Agents section above Apps. It lists the terminal agents that paddock runs as rooms, in the List and the Rooms modes. Examples are Claude Code, Codex, Gemini CLI, Copilot CLI, Grok and opencode. The character color follows the agent: orange claude, blue codex, purple gemini, green copilot, pink grok, teal opencode, gray for the others.

| State | Sprite |
| --- | --- |
| Working | `work` |
| Waiting for you | `wait`, with the request count as a badge |
| Idle, Stuck, Starting | `idle` |
| Ended, Done | `sleep` |
| Failed (blocked or an error exit) | `blocked` |

To start an agent, use New Agent. It opens from the toolbar button, `File > New Agent…` and ⌘N in the Agents section. It also opens when you drop a project folder on the window, the sheet or the Dock icon. Choose the agent, the project folder, how the agent works, the network level and, for a git project, "Work in a new branch". "Ask me before each step" is manual mode. It passes `--manual`, or `--no-yolo` with a paddock that does not have `--manual` yet. A run in manual mode has a "manual" tag on its room. Start runs `paddock run AGENT --network LEVEL [--worktree]` in the folder, in a terminal pane of the window (SwiftTerm, pinned in `project.yml`). The pane gets the environment of "The PATH of your shell" below. If your shell did not answer, the pane starts paddock through your login shell. Stop (⌘. or the Stop button) asks first. Open in Terminal hands the run to Terminal with `paddock view ID --write`.

The launcher reads `paddock list --json`, `recent --json`, `ps --json`, `board --json` and `approvals --json`. The event stream has no agent events. While a run lives, the launcher reads `ps`, `board` and `approvals` every 3 s. If no run lives, it reads only `ps` and `board`, every 10 s. The Questions list shows the agent requests next to the app questions. A request is a host command, a git push, a new server or a device. Its card has No, Yes once and Yes for this session. They notify with the setting of the app questions. A command that this paddock does not have shows "Needs a paddock with …" in its place.

A failed run has a card above its terminal. The card says what failed in plain words and gives the next step. Its buttons are Start Again, Open the Log, Update paddock or Show All Agents. `AgentFailure` maps the known lines of paddock to these words. The line comes from the run: its end reason, its error notes or its board status. Else it is the last error line on the screen of the pane. paddock's line itself is under "Details". For a line that the launcher does not know, the card says "The agent stopped with an error." That line never shows as the message.

The Details tab of a run shows the notes of paddock, grouped by level: errors, questions, warnings and notes, each with its symbol. paddock 0.2.4 gives these notes in `run_notes` of `paddock ps --json`. These are the lines that `--quiet` keeps out of the pane. An older paddock has no `run_notes`, and the tab shows no notes.

A newer paddock also moves the room:

| Field | Command | Motion |
| --- | --- | --- |
| `unread_ask` | `paddock mail ls --json` | The mailbox hops once for an unread question. |
| `loft_commits` | `paddock board --json` | A new commit sends the character up the ladder to the loft. |
| event `kind: "device_call"` | `paddock events --follow --json` | A spark runs along the device cable of the run. |

Without these fields the room has no mailbox, no loft and no cable, and nothing else changes. `Fixtures/agents-024` has all of them.

## The files of a run

paddock 0.2.4 runs an agent on a copy of the project. The room of such a run has a bar at its lower edge. The bar says what waits in the copy, for example "7 changes wait in the copy, 2 in conflict", and has a Files button. An older paddock has no copies, and the bar does not show.

Files opens the Files screen in place of the room:

- On the left, the folder tree with the count of the changes in each folder.
- In the middle, a table with Name, Change, Size and Time. The mark of a file is a symbol and a word: New, Changed, Deleted, Conflict or Kept.
- On the right, the preview. A text file shows your file on the left and the copy's on the right, with line numbers. "Unified" shows one column. A picture shows side by side, or with a slider.
- The toolbar has the filter (Changes, All files, Conflicts), the search, Discard All and Apply All. The header has the pointer chip and Backups.

Each row and each folder has Apply to Original, Keep in the Copy and Discard, in its menu and in the preview. Apply opens a sheet. The sheet lists the files that paddock writes and deletes in your folder, then each conflict with three choices: Use the copy, Keep mine, Merge both. Apply stays off until every conflict has a choice. Backups shows a timeline by day; a point restores whole, or one file of it. The pointer chip opens a popover with the size of the store, the encryption of its disk and one action for the state.

The keys: Space for Quick Look, ⌘↩ apply, ⌘K keep, ⌘⌫ discard, ⌘Z undo the last apply, ⌘[ back to the room.

In the picture of the header, the copy is a small model of the house on the agent's desk, and your folder is the house. The model glows while changes wait. An apply moves the changed parts from the desk to the house in 700 ms. With Reduce Motion, a check mark shows on the house in place of the move.

The code is in `App/Views/Files` and `PaddockKit/Sources/PaddockKit/Files`. `FilesContractTests` holds `Fixtures/copy-v1` to the JSON shapes of the core file `src/copy/json.rs`. Those fixtures are written by hand from the shapes: no file there is the output of a real paddock 0.2.4 yet. The contract gives the JSON of the answers, not the arguments of apply, keep, discard, restore and undo. `FilesArgs.swift` holds what the launcher sends for them, in one place.

## The room art

The Library has a Rooms view: the List / Rooms switch in the toolbar, or View > Show as List and Show as Rooms. The app remembers the choice. Each app is a small room with a character. The character shows the state of the app:

| State | Sprite |
| --- | --- |
| Running with a window | `work` |
| Running with no window yet | `idle` |
| Open questions | `wait`, with the question count as a badge |
| Stopped, Ready or Suspended | `sleep` |
| Starting or Stopping | `idle`, with a spinner |
| Error or Blocked | `blocked` |

The art is in `App/Assets.xcassets/Rooms`, one image set per PNG of the sprite export. `Sprites/README.txt` describes the art and `Sprites/rooms.json` is its geometry. To bring in a new export, run `uv run --with pyoxipng Scripts/import-room-art.py DIR`. The script compresses the PNGs losslessly and copies rooms.json into `rooms.dataset`.

- `character-COLOR-STATE-N`: 512 × 512 px in the @2x slot. COLOR is `gray`, `orange`, `blue`, `purple`, `green`, `pink` or `teal`. N starts at 1 (the file `character-blue-idle-0.png` of the export is the image set `character-blue-idle-1`). The loop ends at the first number that is not there, and it plays at 8 frames per second.
- `room-TINT`: 512 × 512 px. TINT is `cream`, `blue`, `lilac` or `mint`. The cards use the tints in this order.
- `room-front-screen`: the desk and the laptop with its screen to the viewer. A room draws the room, then the character, then this front layer, then the app icon on the laptop screen. The front layer covers the desk of every tint, so every room shows the icon.
- `rooms.dataset/rooms.json`: the rooms.json of the export, unchanged. The rooms take the screen corners and the character place of `room-cream-screen.png`. The icon is as high as the screen, the largest square that stays on it. A card also shows the icon next to the app name.

Inside a room the character uses all five loops. The work loop brings its own laptop: the desk hides it, and the room cuts the loop at the underside of the desk (`CharacterArt.workFloor`). A room loads its art when it comes on screen and releases it when it leaves; character frames are drawn down to 256 px and rooms keep their 512 px.

The characters of the apps differ: an app takes the color of its name unless one of the five apps before it has that color (`CharacterColor.spread`). The cards fill the row and grow to 280 pt when the library has few apps (`RoomGridNavigation.fit`). The last card is the add-app room. The Rooms grid holds the art of all its rooms while it shows, so a scroll does not load a PNG twice, and it loads the art of the rooms below the window edge in the background. All loops change their frame on one shared 8 fps tick. A loop has no timer while its window is hidden, its room is off screen, or Reduce Motion is on.

Each room stands on a stage, a soft panel in the tint of the room. In Dark Mode the stage is a muted mid tone, so the dark outline of the art still shows. `App/Design.swift` holds the spacing steps, the motion and the stage; `RoomStage` in PaddockKit holds the stage colors, and the tests check the contrast of the outline on each.

When a PNG is not there, the app draws a placeholder with shapes and logs the missing name once (subsystem `dev.paddock.mac`, category `rooms`). A placeholder room has a dashed edge and the words "Placeholder art". When you change the art, run the PaddockKit tests: they check rooms.json, the image sets and the size of the art.

A debug build draws the Rooms view in a snapshot when you set `PADDOCK_LAUNCHER_SNAPSHOT_ROOMS=1` together with `PADDOCK_LAUNCHER_SNAPSHOT=DIR`. The snapshot does not change the saved choice.

### The motion of the rooms

A room moves when paddock does something in it. A page gives a room its state (`RoomWorld`: a request, the network, mail, a frozen session, the loft, a child run, the copy), and `RoomSceneView` moves the room from the picture before to the new one. `StagedRoom` hosts that view, so a page places a room as before.

| What paddock does | What the room shows | Length |
| --- | --- | --- |
| A request waits | The character walks to the door with an amber card, then waits with a ring for the time left | 500 ms |
| You answer | The character walks back to the desk | 400 ms |
| The network mode changes | The blind of the window moves: up, half down, down | 300 ms |
| A message comes | The flag of the mailbox goes up. For a question the box hops once | 200 ms |
| The session freezes or thaws | Frost grows from the corners, or melts. The character keeps its pose | 600 ms |
| The agent writes a note | The character climbs the ladder to the loft and writes. The view pans up. A new notebook slides onto the shelf | 600, 350 and 250 ms |
| A device call | A spark runs along the cable of `PlumbingCable`. At a covered socket it stops and a card rises | 400 ms |
| A run spawns a run | A child room builds at the end of a path. An envelope comes back when the child ends | 800 and 500 ms |
| Changes wait in the copy | The model on the desk glows. Apply moves amber parts from the desk to the house | 700 ms |
| Start and stop | The room light turns on and the character wakes, or the light dims and the sleep mask comes down | 400 ms |
| A card opens its detail | The room zooms from the card with a spring | 450 ms |

The rules are in `PaddockKit/Sources/PaddockKit/Motion`: `WorldMotion` names each motion with its length and its curve, and `RoomMotionTrack` gives the frame of any moment. The views are in `App/Views/Motion`. The small parts (card, frost, spark, envelope, ladder) are drawn with shapes in `WorldArt`.

The motion stays cheap. A room draws 30 times a second while a motion runs, and its sprite loop stays at 8 frames a second. A room that is off screen or in a hidden window takes a new state at once and runs no clock. A room with a plain state draws no extra layer. With Reduce Motion a change is a cross-fade of 150 ms and the state swaps at once.

Today the app fills these parts of a room state: the request, the network of an agent run, a frozen session, the light, changed files, and child runs. Mail, the loft, device calls and Apply have their motion and their tests, and they wait for the data of paddock.

A debug build freezes a motion in a snapshot when you set `PADDOCK_LAUNCHER_SNAPSHOT_MOTION=NAME@MS` together with `PADDOCK_LAUNCHER_SNAPSHOT=DIR`. NAME is a raw value of `WorldMotion` and MS is the time after the start of the motion in milliseconds. For example, `request-out@250` shows the character half way to the door. Every room draws that moment, and a window named "Motion NAME@MS" shows it large.

## Related

- [paddock](https://github.com/harnessix/paddock): the command-line tool. It runs coding agents and desktop apps in sandboxes on Linux and macOS.

## License

MIT. See [LICENSE](LICENSE).
