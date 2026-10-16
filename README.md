# xeneon-touch

**Make the CORSAIR XENEON EDGE work as a real touchscreen on macOS.**

On a Mac, the XENEON EDGE's touch panel behaves like a trackpad. Touches drag the cursor around your whole desktop instead of clicking where your finger is. Corsair's iCUE app, which handles touch on Windows, doesn't support the Edge on macOS.

`xeneon-touch` is a tiny (~200 lines of Swift, no dependencies) background agent that fixes this. Tap a button on the Edge and it gets clicked.

| Gesture on the Edge | What happens |
|---|---|
| Tap | Click at that spot |
| Double tap | Double click |
| Touch and drag | Drag (move windows, select text, sliders) |
| Touch, hold ~0.3s, then move | Press and drag |
| Two-finger drag | Scroll |

Rotated mounting (portrait) is handled automatically.

## Install

Requires macOS 11+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/brenoca/xeneon-touch.git
cd xeneon-touch
make install
```

This builds the agent, installs it as `~/Applications/XeneonTouch.app`, and registers a LaunchAgent so it starts at login and restarts if it exits.

### Grant permissions (one time)

macOS will prompt for two permissions. You can also turn them on in **System Settings → Privacy & Security**:

- **Input Monitoring** → enable **XeneonTouch**. This lets it take exclusive control of the touch controller, so macOS stops moving the cursor like a trackpad.
- **Accessibility** → enable **XeneonTouch**. This lets it post clicks and drags.

If XeneonTouch isn't listed, click **+** and add `~/Applications/XeneonTouch.app`. Then restart it:

```sh
make restart
```

## Commands

```sh
make install     # build, install, start at login
make restart     # restart the agent (e.g. after granting permissions)
make log         # follow the log (/tmp/xeneon-touch.log)
make uninstall   # stop and remove everything
```

> Rebuilding re-signs the app ad hoc, so macOS may ask you to re-grant the permissions after a `make install`.

## How it works

The Edge's touch panel is a separate USB device from the display: a WCH controller (`27C0:0859`) that exposes a standard 10-point HID multi-touch digitizer plus an absolute-mouse interface. macOS has no touchscreen support, so it turns that input into cursor movement.

`xeneon-touch`:

1. Uses IOKit to **seize** the digitizer and mouse interfaces (`kIOHIDOptionsTypeSeizeDevice`), so macOS no longer processes them.
2. Parses the raw touch reports and maps each contact onto the bounds of the display named **XENEON EDGE**, accounting for its position in your display arrangement and its rotation.
3. Posts ordinary mouse and scroll events via `CGEvent`, using a small gesture state machine. A touch isn't pressed immediately, so scrolling never starts with a stray click.

It doesn't install a kernel or driver extension, and it doesn't use the network.

## Troubleshooting

- **Nothing happens / cursor still acts like a trackpad.** Check `make log`. `cannot seize interface` means Input Monitoring isn't granted. `Accessibility not granted` means clicks are being dropped. Grant both, then `make restart`.
- **`no display named XENEON EDGE found`.** The agent looks the display up by name. Make sure the Edge is connected as a display, not only over USB.
- **Taps land in the wrong place.** Run `./xeneon-touch --debug` from the repo while touching the screen. It prints raw HID reports. Please open an issue with that output and your macOS version.
- **Different touch controller.** If `system_profiler SPUSBDataType` shows your Edge's "TouchScreen" with a different vendor/product ID, change `vendorID`/`productID` at the top of `main.swift`.

Tested on macOS 26 (Apple Silicon) with a XENEON EDGE 14.5". Reports from other setups are welcome.

## License

MIT. Not affiliated with or endorsed by Corsair. CORSAIR and XENEON are trademarks of their respective owner.
