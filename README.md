# SwipeToVSCode

Three-finger swipe back/forward for VS Code on macOS.

This uses macOS's private `MultitouchSupport` framework to read raw trackpad touches, then sends VS Code's default navigation shortcuts:

- Back: `Ctrl+-`
- Forward: `Ctrl+Shift+-`

Because `MultitouchSupport` is private Apple API, this is a personal utility, not an App Store-safe app.

## Run Manually

```sh
./run-swipetovscode.sh
```

If macOS asks for Accessibility permission, allow the terminal app you used to run it.

## Start At Login

```sh
./install.sh
```

This installs a user LaunchAgent at:

```text
~/Library/LaunchAgents/com.jameshutchison.swipetovscode.plist
```

If the LaunchAgent starts but shortcuts do not post, open `System Settings > Privacy & Security > Accessibility` and make sure the relevant runner is enabled. Depending on how you launched it, macOS may list your terminal app, VS Code, or `swift`.

## Uninstall

```sh
./uninstall.sh
```

## Debugging

In `SwipeToVSCode.swift`, set:

```swift
private let debugLogging = true
```

Then run `./run-swipetovscode.sh` and watch the terminal output.
