# ditooctl

Control an original Divoom Ditoo from macOS. Requires macOS 13+; supports Intel and Apple Silicon.

## Install

```sh
brew install leoshimo/tap/ditooctl
brew upgrade leoshimo/tap/ditooctl
```

Homebrew installs a compiled binary. Swift and Xcode are not required to run it. [Release archives](https://github.com/leoshimo/ditooctl/releases) include a standalone installer.

Pair **Ditoo-audio** on the Mac that will control it, using `device pair` below or System Settings → Bluetooth. Allow Bluetooth access for the terminal or host application when macOS asks.

## Use

```sh
ditooctl device list --scan
ditooctl device add desk AA:BB:CC:DD:EE:FF
ditooctl device pair desk

ditooctl status --json
ditooctl brightness 60
ditooctl mode clock --color 00FFB0
ditooctl mode custom

ditooctl show picture.png
ditooctl show animation.gif --check --json
ditooctl show animation.gif

ditooctl text "42"
ditooctl text "BUILD COMPLETE" --scroll
```

The first added device becomes the default if none is configured. Use `device use NAME` to change it or `--device NAME_OR_ADDRESS` for one command. `device remove NAME` forgets the local name without unpairing.

`device pair [NAME_OR_ADDRESS]` starts Bluetooth pairing on this Mac; omit the target to use the default. Already-paired devices return immediately. PIN/code confirmation, if needed, requires an interactive terminal. Disconnect the Ditoo from another host if it cannot be found. Bluetooth permission and pairing belong to the hosting Mac; an SSH session may not be able to show permission prompts.

Omit the value from `brightness` or `mode` to read it. Modes: `clock`, `light`, `gallery`, `visualizer`, `custom`, `off`. Clock/light accept `--color RRGGBB`; other settings are preserved from a live read. `off` blanks the display without turning off the speaker.

## Media and output

PNG and GIF files must be **16×16**. GIFs allow 1–60 frames and up to 51,200 encoded bytes. Alpha composites onto black; full opaque frames are recommended. `show --check` validates offline. `show --help` documents timing, formats, limits, and authoring examples.

Static text allows 1–4 characters; scrolling allows 1–40. Supported: A–Z, digits, spaces, `- . !`. Lowercase converts to uppercase. Text is white on black unless `--color RRGGBB` is supplied.

Each command connects, operates, and exits. Uploaded animations keep looping. Ordinary upload retention across power cycles is unverified; saved-slot editing and audio commands are not included.

`--json` writes one JSON value to stdout. Errors use stderr and a nonzero exit status. `--verbose` adds Bluetooth diagnostics. Hardware operations stop after 90 seconds at most and do not retry uncertain writes. Close competing phone apps/controllers if a connection times out.

Only names, addresses, and the default are saved in `$XDG_DATA_HOME/ditooctl/devices.json` (default `~/.local/share/ditooctl/devices.json`). Display state is read live; unavailable values stay unknown. Status cannot retrieve displayed pixels or filenames.

## Build

```sh
swift build -c release --product ditooctl
./scripts/install.sh                  # ~/.local/bin
./scripts/package.sh 0.1.4            # universal release; requires Xcode
```

[Distribution workflow](docs/distribution.md). Code: MIT.
