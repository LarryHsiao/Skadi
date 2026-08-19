# iOS Simulator

Default to `idb` (Meta's iOS debug bridge) for driving a booted iOS Simulator — tap, swipe, type text. It talks to CoreSimulator directly, so it works even with the Simulator window minimized, unfocused, or off the visible screen — unlike screen-coordinate clicks through a computer-use tool, which need the window focused and on-screen to land on the right pixel. Keep `xcrun simctl` for what `idb` doesn't do: booting/terminating the device, launching an app by bundle ID, opening a URL, and taking screenshots.

## Driving (idb)

```bash
idb list-targets                                    # booted/available simulators + UDIDs
idb ui tap <x> <y> --udid <udid>                     # tap a point
idb ui swipe <x0> <y0> <x1> <y1> --udid <udid>       # swipe/drag
idb ui text "some text" --udid <udid>                # type into the focused field
idb ui key <keycode> --udid <udid>                   # press a hardware/keyboard key
idb ui describe-all --udid <udid>                    # dump the on-screen accessibility tree — use this to find tap targets rather than guessing coordinates from a screenshot
```

## Lifecycle & screenshots (simctl)

```bash
xcrun simctl list devices                            # UDIDs + boot state
xcrun simctl boot <udid>                              # boot — never do this without the user's ask; see feanor/manwe's "you boot the device" rule
xcrun simctl launch <udid> <bundle-id>
xcrun simctl terminate <udid> <bundle-id>
xcrun simctl openurl <udid> <url>
xcrun simctl io booted screenshot out.png             # feanor/manwe's shot hooks already wrap this
```

## If idb is missing

Check with `command -v idb` before falling back to screen-coordinate clicks. If it's absent, stop and prompt the user to install it rather than silently driving by screenshot coordinates — a click that requires the Simulator window focused and visible is a worse default once idb is an option:

```bash
brew tap facebook/fb && brew install idb-companion
pip install fb-idb
```
