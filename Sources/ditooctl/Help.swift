import Foundation

let version = "0.1.2"
let help = """
ditooctl \(version) — a direct remote for the original Divoom Ditoo

Usage: ditooctl [--device NAME_OR_ADDRESS] [--json] [--verbose] COMMAND

  device list [--scan]        List saved and paired Ditoos; optionally discover
  device add NAME ADDRESS    Save a name; use as default if none is configured
  device use NAME            Change the default
  device remove NAME         Forget the local name (keeps Bluetooth pairing)
  status                     Read live display settings
  brightness [0...100]        Read or set global display brightness
  mode [MODE] [--color RGB]   Read or select a mode, preserving its settings
  show FILE [--check]         Upload a 16×16 PNG/GIF, or validate it offline
  text TEXT [--scroll]        Display short text or upload scrolling text

Modes: clock, light, gallery, visualizer, custom, off.
--color uses RRGGBB and applies to clock/light. off blanks the screen only.

Use COMMAND --help or help COMMAND for formats, limits, examples, and semantics.
--json produces machine-readable output; diagnostics always go to stderr.
--verbose includes Bluetooth diagnostics. --version prints the version offline.
Use -- before positional values beginning with '-'.

Only device names/default are saved, in $XDG_DATA_HOME/ditooctl/devices.json
(default ~/.local/share/ditooctl/devices.json). Device values are read live.
Commands connect, operate, and exit. Uploaded GIFs loop without a controller.
"""

let commandHelp: [String: String] = [
"device": """
Manage local names and the default device.

  ditooctl device list [--scan] [--json]
  ditooctl device add NAME ADDRESS
  ditooctl device use NAME
  ditooctl device remove NAME

NAME is required: 1–64 ASCII letters/digits, '-' or '_', starting with a letter
or digit. ADDRESS is a Bluetooth MAC (colon or hyphen separated).
add fails for duplicate names; it sets the default only if no default exists.
remove clears the default if selected and never unpairs the device.
list shows saved names plus paired Ditoos from macOS; --scan searches nearby
for 8 seconds (name resolution can add 15 seconds). Inventory connection flags
are macOS metadata, not a successful control-channel check; use status for that.

Pair the device in System Settings → Bluetooth on the Mac that will control it.
add does not pair or contact it. It saves no brightness, mode, or artwork.
--device does not apply to these local registry commands.
""",
"status": """
Read live display state from the selected device.

  ditooctl status [--json]
  ditooctl --device desk status --json

Returns device name/address, successful communication, reported mode, brightness,
and settings for the reported mode. Missing/unknown values are null, never cached.
Mode settings include clock color/style/information options, or light color,
brightness/effect. The report cannot retrieve displayed pixels or a filename,
battery/firmware, or reliably describe every temporary overlay.
The physical Sun-key blank screen can still report its underlying mode.
No reply is an error. --json writes one object to stdout; diagnostics use stderr.
Hardware operations have an overall 90-second deadline, including macOS lookups.
""",
"brightness": """
Read or set global display brightness on the device.

  ditooctl brightness [0...100] [--json]

Omit the value to read. Supply an integer percentage to set it and verify a live
readback. Does not change image RGB, clock settings, or local preferences.
Zero brightness is separate from mode off. Values outside 0–100 are rejected
before connecting. There is no offline setter because success needs a live reply.
""",
"mode": """
Read/select a display mode; edit only explicitly supplied options.

  ditooctl mode [--json]
  ditooctl mode clock [--color RRGGBB]
  ditooctl mode light [--color RRGGBB]
  ditooctl mode gallery
  ditooctl mode visualizer
  ditooctl mode custom
  ditooctl mode off

clock: built-in clock. light: colored light. gallery: device HOT gallery.
visualizer: built-in sound visualization; does not start audio playback.
custom: return to current custom artwork without uploading a file.
off: blank the display via disabled night-light; speaker/device remain on.

Clock/light settings come from a fresh device read and are preserved unless
changed explicitly. Light/off preserves its separate brightness and effect;
light enables that light. Clock selection does not synchronize device time.
Writes require acknowledgement and matching readback; no missing fields are
replaced with local defaults. Firmware/model support can vary and errors remain
errors. The original Ditoo is the target; other Divoom models are not claimed.

Some temporary screens report an underlying channel; mode is a device report,
not a screenshot. There are no saved-artwork slot editing/deletion commands.
""",
"show": """
Upload artwork, or validate it offline with the same decoder/encoder.

  ditooctl show picture.png
  ditooctl show blossom.gif
  ditooctl show blossom.gif --check [--json]

File contents determine the format. PNG and GIF only, exactly 16×16 pixels.
No automatic resize, crop, or rotation. RGB/RGBA/indexed PNGs are accepted.
Alpha composites onto black, not the previous display. Non-RGB colors convert
to sRGB; the palette is generated automatically (at most 256 colors/frame).
Bake orientation into pixels. Use high contrast and strokes at least 1 pixel wide.

GIF: 1–60 frames; full opaque frames on black are recommended. Arbitrary GIF
disposal/transparency patterns are not guaranteed by the native decoder. Frame
delays keep 10 ms GIF precision: missing/zero becomes 100 ms, shorter delays clamp
to 10 ms, above 65,535 ms fails. 100–200 ms is a useful authoring starting point.
Encoded animation data must fit 51,200 bytes; compressed file size is unrelated.
These are encoder limits, not measured firmware maxima. APNG is not supported.

Uploads select the custom display, preserve global brightness, and require a
device acknowledgement. GIFs repeat after this command exits; finite GIF loop
counts are ignored. Another image/mode replaces playback. Ordinary uploads alone
have not been isolated for power-cycle retention; there is no persistent-slot API.

--check never loads device configuration, connects, or uploads. It reports format,
dimensions, frames, timing, encoded bytes, and packet count; invalid files fail.
Uploads validate before connecting too. Acknowledgement does not prove appearance.

Agent workflow: generate full 16×16 frames → validate with --check → inspect an
enlarged nearest-neighbor preview with your image tool → upload the original file.
Blossom is ordinary GIF artwork, not a special file format or command.
""",
"text": """
Render text as pixels; scrolling runs on the Ditoo after this command exits.

  ditooctl text "42" [--color RRGGBB]
  ditooctl text "BUILD COMPLETE" --scroll [--color RRGGBB]

Static text: 1–4 characters. Scrolling: 1–40 characters. ASCII lowercase converts
to uppercase. Supported: A–Z, 0–9, spaces, hyphen, period, exclamation mark.
Font: built-in 3×5 glyphs; short static text is enlarged. White on black by default.
--color changes only rendered pixels, not global brightness. Unsupported text
fails before connecting. Quote TEXT as one shell argument (use -- before a value
beginning with '-'). Scrolling uses up to 60 frames at 130 ms per pixel of travel;
long strings move several pixels per frame to keep the complete text in the loop.
Text replaces the current custom artwork. Scripts own counters/timers/state.
"""
]
