# Codex Pet Limit Rings

Codex Pet Limit Rings is a native macOS companion app for Codex pets. It does not patch Codex, replace pet art, or modify the Codex app bundle. It follows the current pet with a transparent always-on-top window that matches Codex's pet window level when available, and exposes its own menu-bar icon.

The rings are pet-agnostic. They work with any pet Codex displays because the app tracks the pet window bounds rather than reading, editing, or understanding the pet artwork.

## Experience Contract

- A tiny two-ring usage meter appears in the macOS menu bar, using the same outer short-window and inner weekly limit colors as the pet overlay.
- `Show Rings` toggles the overlay without quitting the app.
- `Ring Style` switches between `Segmented Pixel`, `Classic Glow`, and `CRT Glow`, and the choice persists across relaunches.
- `Pixel Cloud` toggles the outer-ring pixel aura for every ring style, and the choice persists across relaunches.
- `Orbiting Glints` toggles the animated square glints independently of the pixel cloud, and the choice persists across relaunches.
- `Glint Speed` switches between the original calm cadence and a usage-responsive cadence. Responsive glints track a smoothed rate of allowance consumption for their corresponding rings, ignore resets and refills, and retain a gentle idle speed.
- `Refresh Now` rereads usage and pet-position state.
- `Copy Debug Geometry` copies screen, pet, overlay, and panel frames for diagnosing positioning issues.
- Hovering over the ring or pet shows exact remaining percentages at the arc endpoints.
- Dragging the pet makes the rings follow the gesture immediately while Codex persists the new position.
- The animated orbit highlights use two Core Animation layers, with style-specific square glints positioned outside or inside the ring tracks so they do not flicker under segmented cells.
- Dynamic pixel dust is available across all styles and is emitted from the outer ring only: small square pixels of varied size drift outward, shrink, and fade so the glow feels like it is shedding a light pixel aura without continuous AppKit redraws.
- The rings use Codex's own pet overlay window level when detectable, with an always-on-top fallback, so ordinary app windows do not cover the rings.
- The rings are ordered below Codex's own pet message and controls when the pet overlay window can be matched, so bubbles and buttons remain visually clear.
- Closing the Codex pet hides the rings.
- Multi-display positioning uses the screen containing the pet bounds, not the currently focused screen.
- macOS desktop/Space switching keeps the rings visible with the pet rather than tying them to one active desktop.
- Switching to another Codex pet requires no extra setup; the overlay follows the active pet.

## Data Flow

The app reads live usage first, then local files as support or fallback:

- `https://chatgpt.com/backend-api/wham/usage`: live usage endpoint, called with the local ChatGPT access token from `~/.codex/auth.json`.
- `~/.codex/auth.json`: local ChatGPT auth token used for the live usage call.
- `~/.codex/.codex-global-state.json`: current pet bounds, using `electron-avatar-overlay-bounds.mascot`.
- `electron-avatar-overlay-open` in the same state file: whether the Codex pet is currently open.
- `~/.codex/logs_2.sqlite`: fallback source using the newest `codex.rate_limits` event when the live usage call fails.

The app watches `~/.codex/.codex-global-state.json` with a macOS file event source, so pet open/close and position writes trigger an immediate frame update. A slow frame timer remains as a fallback in case the file is replaced or an event is missed. Pet coordinates are resolved against the display recorded by Codex when available. When Codex reports `displayBounds`, that frame is used as the top-left coordinate origin for the target display, which keeps secondary-monitor offsets from being treated as display-local zero-based coordinates. The frame reader accepts both the original complete overlay record and the newer abbreviated per-display record. In the abbreviated form, `x` and `y` are treated as the mascot anchor while compatible saved display geometry supplies its size and overlay offset; a conservative built-in geometry is used only when Codex has not retained any detailed display record.

No OpenAI API key is required. The menu summary says `Live` when the direct usage read succeeds and `Cached` when it is showing the local event-log fallback.

Live usage checks use an ephemeral, cacheless URL session. The app reads the local ChatGPT token to make the request but does not persist HTTP cache data or write token values to its logs.

Usage polling is adaptive: it checks every 10 seconds while Codex is frontmost or recent allowance consumption has been observed, every 45 seconds while idle, and every 20 seconds while waiting for initial data. Activating Codex or waking the display prompts an early refresh. Glint speed is calculated from smoothed percentage consumption rather than presented as a literal token counter, since the endpoint reports allowance snapshots rather than per-token events.

## Source Map

The app is intentionally still a small source-buildable companion rather than a framework-heavy macOS project. The main source lives in `tools/codex-pet-limit-rings.swift`, with responsibilities grouped by type:

- `LimitStateReader` reads live usage and falls back to local Codex rate-limit events.
- `PetFrameReader` reads Codex pet state and matches the live Codex overlay window when possible.
- `LimitRingRenderer` draws the static ring artwork for each style.
- `LimitRingView` owns compositor-backed effects such as pixel dust and orbiting glints.
- `LimitRingsApp` owns the menu-bar item, panel lifecycle, frame following, and debug geometry.

Keep future changes inside the narrowest matching area. A larger source split can come later, but the current hygiene goal is to keep the tiny companion app easy to inspect, validate, and ship.

## Rendering Model

- Outer ring: short-window remaining percentage.
- Inner ring: weekly remaining percentage.
- `Segmented Pixel` renders the rings as segmented pixel-cell dials so they sit naturally beside 1990s/early-2000s pet sprites.
- `Classic Glow` restores the smoother luminous ring feel with small pixel accents and softer glints.
- `CRT Glow` uses continuous glowing arcs, optional dynamic pixel dust, optional tiny square glints, and a brighter scanline-like bloom.
- Ring colors are derived from remaining capacity: green/blue for healthy, amber for low, red for critical.
- Exact percentages are shown only on hover to keep the pet feeling ambient rather than dashboard-like.
- Additional model-limit buckets may appear as small outer markers when available.
- Small square orbit highlights are compositor-driven layer animations and can be toggled independently, so the rings can stay lively without forcing continuous AppKit redraws.
- Usage-responsive glints adjust the playback rate of those existing Core Animation layers without adding a display timer. Speed changes preserve the current orbit phase, remain bounded, and are smoothed over time to avoid jumps when usage snapshots update in batches.
- Subtle static pixel dither appears around glow styles, while optional live outer-ring dust uses a low-rate outline emitter with a lighter wander layer so the effect feels like a quiet pixel aura and remains lightweight.
- Compositor-backed dust and orbit layers are re-armed after system wake or display changes, so a stale `CAEmitterLayer` can recover without asking the user to toggle the pixel cloud manually.

## Install Contract

`tools/install-limit-rings.sh` builds:

```text
~/Applications/CodexPetLimitRings.app
```

and installs:

```text
~/Library/LaunchAgents/com.codex-pet.limit-rings.plist
```

The LaunchAgent starts the app at login and restarts the companion after an unsuccessful exit, with a short throttle interval so repeated crashes do not spin. The installer also removes the earlier prototype app and LaunchAgent names if present:

```text
~/Applications/CodexLimitAura.app
~/Library/LaunchAgents/com.codex-pet.limit-aura.plist
```

`tools/uninstall-limit-rings.sh` unloads the LaunchAgent, removes the app bundle, clears saved ring preferences, and also cleans up those earlier prototype names.

## Development

Build and run the app from the repository:

```bash
tools/run-limit-rings.sh
```

Run the standard hygiene check:

```bash
tools/validate-limit-rings.sh
```

That script checks shell syntax, compiles the app, runs synthetic old/new pet-state schema tests, renders previews for every ring style, builds an app bundle under `tmp/`, and runs `git diff --check` when available.

Render a static preview:

```bash
swiftc tools/codex-pet-limit-rings.swift -o tmp/codex-pet-limit-rings -framework AppKit -framework QuartzCore -lsqlite3
tmp/codex-pet-limit-rings --preview tmp/limit-rings-preview.png --size 164 --style segmented-pixel
tmp/codex-pet-limit-rings --preview tmp/limit-rings-crt-preview.png --size 164 --style crt-glow
```

## Codex Skill

The repository includes a skill at `skills/codex-pet-limit-rings/`. Copy that folder into `~/.codex/skills/` or run `tools/install-codex-skill.sh` to make Codex auto-discover the workflow in future sessions.

The skill intentionally points agents at the companion-app boundary and validation commands. It should not encourage app-bundle patching as the default path.
