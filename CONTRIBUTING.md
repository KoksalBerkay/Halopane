# Contributing to Halopane

Thanks for wanting to help. Halopane is maintained by one person in spare time, so a few simple rules keep it manageable.

## Ways to help

- **Tell us about your hardware.** If you tried glasses, an adapter or an iPhone that is not in the README table, open an issue and say what worked and what did not. This is as valuable as code.
- **Report a bug.** Use the bug report template.
- **Fix or improve something.** See below.

## Before you write code

For anything bigger than a small fix, open an issue first and describe what you want to change. It saves you from building something that cannot be merged.

Keep each pull request to one topic. Small pull requests get reviewed quickly; large mixed ones do not.

## What a good pull request includes

- What changed and why, in plain words.
- How you tested it, and on what: glasses, adapter, iPhone model and iOS version. If you could only test on the Mac, say so. That is fine, it just needs to be stated.
- Passing tests:

  ```sh
  swift test
  swift test --package-path AdapterTracking
  ```

  If you touched rendering, web input or media, also run the checks in `Verification/` that cover it:

  ```sh
  ./Verification/logic-tests.sh         # typed addresses, search and sign-in rules
  ./Verification/webkit-smoke.sh        # page scripts, media control, right-click
  ./Verification/web-texture-smoke.sh   # run after webkit-smoke; uses its snapshot
  ./Verification/render-preview.sh      # 3D scene and pointer in Metal
  ./Verification/native-media-smoke.sh  # Spatial Player decoding and routing
  ./Verification/depth-3d-smoke.sh      # 2D-to-3D: depth model, mesh and stereo warp
  ./Verification/ad-blocking-smoke.sh   # filter rules in WebKit
  node Verification/catalog-scroll.cjs  # GeForce NOW scrolling
  node Verification/shorts-scroll.cjs   # YouTube Shorts scrolling
  ```

## Where code lives

The folder table under "How it is organised" in the [README](README.md) lists what each folder holds. A few names to know:

- `BrowserScreen` is one browser screen in the glasses. Its code is split by feature into `BrowserScreen*.swift` files in `Sources/Browser/Core/`.
- `Workspace` holds the state all screens share: the screen list, full screen, placement, input mode, preferences, history and bookmarks. Every screen holds the same instance. Workspace actions run on the first screen, `owner`.
- `GlassesSurface` draws every screen in the glasses. `GlassesDisplay` holds the shared display and tracking state.
- `BrowserShell` is the phone controller. `Resources/` holds the scripts injected into web pages.

## Code quality

The goal is code that someone new to the project can read, trust and change. In review, this is what matters:

- **Easy to follow.** Clear names, functions that do one thing, and files grouped by feature. If a function or file is getting hard to hold in your head, split it.
- **Comments explain why.** The code says what it does. Use comments for the reasons the code cannot show: an iOS quirk, a WebKit workaround, a value found by testing on the glasses.
- **Fits in.** Follow the patterns in the code around your change, and put new code in the folder for its feature.
- **Tested where it can be.** Logic that runs on the Mac, such as geometry, input routing and parsing, should come with a test in `Tests/` or `Verification/`.
- **No hidden costs.** Ask in an issue before adding a dependency, a new private iOS interface or a new network request.
- **Reviewable commits.** Keep formatting, renames and behaviour changes in separate commits, so each one is easy to check.

Formatting is handled by tools, so nobody has to argue about it. Swift uses `.swift-format` and Objective-C uses `.clang-format`. Run these before you open a pull request:

```sh
xcrun swift-format lint --configuration .swift-format -r Sources Tests Verification AdapterTracking
xcrun clang-format --dry-run Sources/PrivateWebPortal/*.[mh]
for file in Resources/*.js; do node --check "$file"; done
```

## AI assistance

AI tools are welcome here.

If an AI model wrote or substantially shaped part of your contribution, say so in the pull request and name the model and the tool, for example **Claude Opus 5.5 in Claude Code**.

You are responsible for every line you submit, however it was written. Read it, understand it and test it.

## Hardware safety

- **No new device commands.** Halopane sends the adapter only commands that were observed coming from the vendor's own app. Do not add commands to the adapter or the glasses in a pull request. If you have evidence for a new one, open an issue and show it first.
- **Keep the setup simple.** At runtime Halopane uses only the iPhone, the glasses and the adapter. No cameras, no extra bridge hardware, no computer.

## Protect your own privacy

Bluetooth captures, sysdiagnose archives and crash logs contain your device's name and serial number.

- Never attach raw captures or archives to a public issue.
- The report from **Settings → Troubleshooting → Share report** leaves out the sites you visit, apart from well-known services. It is safe to attach.
- Mask device names and serial numbers.

## Licence and sign-off

Contributions are accepted under GPL-3.0-or-later.

Add a [Developer Certificate of Origin](https://developercertificate.org/) sign-off to each commit to confirm you wrote the change or have the right to submit it:

```sh
git commit -s
```

For larger contributions the maintainer may also ask you to accept the short [contributor licence agreement](docs/contributor-agreement.md). It lets the maintainer distribute Halopane under other terms in the future, while your contribution stays available to everyone under the GPL. The sign-off and the agreement are separate; a sign-off alone does not accept the agreement.

## Be kind

Everyone here is a volunteer. See the [code of conduct](CODE_OF_CONDUCT.md).
