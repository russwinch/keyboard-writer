# Keyboard Writer

A small macOS app for flashing ZMK firmware onto a split keyboard (and its
dongle). Plug the devices in, press Start, and each one is flashed in order
with its own firmware. No double-tapping reset, no dragging files.

It has two halves:

- **The app** draws the keyboard, shows which device it is working on, and
  copies the right `.uf2` onto each device's bootloader drive.
- **A ZMK module** (`firmware/`) gives each device a USB serial port. Over it
  the device says which one it is, and starts its bootloader when the app asks.

A device whose firmware doesn't have the module yet (or is too broken to
answer) still works: double-tap reset and the app carries on from there.

Not yet tried on real hardware: see "State of things" below.

## The app

```sh
./build.sh                         # needs Xcode or its command line tools
open "build/Keyboard Writer.app"
```

Pick the keyboard, click a device to leave it out, and press Start.

The firmware is the newest build of `main` in the config repo, fetched when
you press Start. "Choose…" lists the recent builds from every branch, and
also takes a zip or a folder of `.uf2` files from this Mac. With no builds to
offer (or no network) it uses the newest `firmware*.zip` in `~/Downloads`.
See "Builds from the config repo" below for the config repo's side of this.

"Reset settings first" flashes `settings_reset` before each device's firmware,
which clears its Bluetooth pairings; each device is then done twice, so leave
it plugged in.

The app only sends a device into its bootloader if it says it is the one
wanted, and never copies onto a board of the wrong type.

### Keyboards

`targets.json` lists the keyboards: each device, the firmware file it takes
and its controller. The firmware name is the first shield of the build (or its
`artifact-name`), so keep it in step with the config repo's `build.yaml`.
Devices are flashed in the order listed.

### Builds from the config repo

The app reads the config repo's GitHub releases, so it needs no login (the
artifacts of an Actions run can't be downloaded without one, even from a
public repo). Each release is one build: its name is what the list shows, its
attached `.zip` holds the `.uf2` files, and builds of branches other than
`main` are marked as prereleases.

The config repo publishes them with one more job in
`.github/workflows/build.yml`, after ZMK's own `build` job:

```yaml
  # One release per build, for Keyboard Writer to list and download.
  release:
    needs: build
    if: github.event_name != 'pull_request'
    runs-on: ubuntu-latest
    permissions:
      contents: write
      actions: read
    env:
      GH_TOKEN: ${{ github.token }}
      GH_REPO: ${{ github.repository }}
    steps:
      - name: Publish the firmware
        run: |
          gh run download "$GITHUB_RUN_ID" --name firmware --dir firmware
          find firmware -name '*.uf2' -exec zip -q -j firmware.zip {} +
          subject="$(gh api "repos/$GH_REPO/commits/$GITHUB_SHA" --jq '.commit.message | split("\n")[0]')"
          tag="build-$GITHUB_RUN_NUMBER"
          gh release delete "$tag" --yes --cleanup-tag 2>/dev/null || true  # a re-run
          if [ "$GITHUB_REF_NAME" = "${{ github.event.repository.default_branch }}" ]; then kind=--latest; else kind=--prerelease; fi
          gh release create "$tag" firmware.zip --target "$GITHUB_SHA" $kind \
            --title "$GITHUB_REF_NAME · $subject" --notes "Built from $GITHUB_SHA."

      - name: Keep the newest 30
        run: |
          gh release list --limit 200 --json tagName --jq '.[30:][].tagName' |
            xargs -r -n 1 gh release delete --yes --cleanup-tag
```

The app asks `russwinch/zmk-config`. To ask another repo:

```sh
defaults write com.github.russwinch.keyboard-writer repo owner/name
```

## The firmware module

In the ZMK config repo, add the module to `config/west.yml`:

```yaml
    - name: keyboard-writer
      url: https://github.com/russwinch/keyboard-writer
      revision: main
```

and give every build the serial port, in `config/default.overlay`:

```dts
#include <keyboard_writer.dtsi>
```

ZMK reads `default.overlay` only when `config/` has no overlay named after the
shield or board; if it has, put the include in that one.

That is all: `CONFIG_KEYBOARD_WRITER` is on by default once the port exists.
The module needs a board with the legacy Zephyr USB stack and retained boot
mode, which ZMK's `nice_nano` and `xiao_ble` have. It does nothing while the
board is off USB power.

How it works (`firmware/src/usb_trigger.c`): when the port is opened the
device writes `keyboard-writer <first shield>`, e.g.
`keyboard-writer waterfowl_left`; when the port is set to 1200 baud it reboots
into the bootloader.

## Development

`Sources/WriterCore` is plain Foundation and holds everything but the UI; it
builds and tests on Linux too (`swift test`). `Sources/KeyboardWriter` is the
SwiftUI app. The App workflow tests, builds, and runs the built app through a
full flash against pretend drives (`smoke.sh`), uploading screenshots.

## State of things

- The app has been run end to end in CI against pretend drives, and the
  module compiles for `nice_nano` and `xiao_ble`.
- The config repo publishes its builds as releases, and the list and the
  zip can be fetched from them without a login. The app's own fetching and
  its builds menu have only been compiled and unit tested, not run.
- Neither has been tried on a real keyboard yet, so the USB conversation
  between them is untested.
