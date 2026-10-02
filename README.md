# Stratlab

Valorant strats (post-plant lineups, entries, smokes, one-ways, flashes, recon, sentinel site
setups): an in-game overlay, plus the app that builds the library. Nothing to install: both run
on the PowerShell and .NET that ship with Windows.

## Installing

Get `Stratlab-Setup-<version>.exe` from the Releases page and run it. It installs per user into
`%LocalAppData%\Stratlab` (no admin rights), adds Start menu and desktop shortcuts, starts the
server at login, and makes `.stratlab` packs open in the app when double-clicked. Upgrades keep
your strats, packs and settings. The installer is not code-signed (certificates cost money), so
Windows SmartScreen shows a warning the first time: click "More info", then "Run anyway".

Building it yourself: install Inno Setup 6 (free, `winget install JRSoftware.InnoSetup`), set the
version in `version.json`, and run:

```
powershell -ExecutionPolicy Bypass -File tools\build_installer.ps1
```

The setup file lands in `dist\` together with a `.sha256` checksum: publish a GitHub release tagged
`v<version>` with both files attached. With git and the GitHub CLI installed (`winget install Git.Git GitHub.cli`,
then `gh auth login --web` once), `tools\release.ps1 -Version 1.0.1` does all of that in one go: bumps
`version.json`, builds, commits, tags, pushes and publishes the release. From a computer without Windows (or without Inno Setup),
the **Release** GitHub Action does the same on GitHub's Windows machine: `gh workflow run release.yml -f version=1.0.1`
(or Actions › Release › Run workflow on GitHub). Without Inno Setup,
`tools\build_portable.ps1` builds `dist\Stratlab-<version>.zip` instead: unzip anywhere, run `Install.bat` once.

**Updates**: with `"repo": "owner/name"` set in `version.json`, the app checks that repository's
latest release every time it opens. The version chip in the header says what it found: a green dot and
"up to date", a grey dot when GitHub could not be reached (click it to try again), or a green **Update**
button when a newer release is out; that button downloads the installer, verifies it against the
published checksum, installs it silently and restarts the app, keeping your strats.

**Marketplace**: with `"catalog": "owner/name"` set in `version.json`, the cart button in the header
opens the Marketplace: the packs published in that repository's `catalog.json`
(see [stratlab-packs](https://github.com/TitanJammer/stratlab-packs)), with filters by agent, map, strat
type, installed state and how recently they were posted, plus sorting and search. Install downloads the
pack from the repository's releases, checks its SHA-256 against the catalog and opens the usual import
preview; an installed pack shows **Installed**, or **Update** when a newer export was published. Packs
are published by posting the `.stratlab` file in the Stratlab Discord's #share-packs channel; `"discord"`
in `version.json` is the invite behind the Discord button and the Marketplace's join link. The book
button is your own **Library** of packs.

**Upvotes**: with `"votes"` in `version.json` set to a Discord webhook URL (see the packs repository's
README), marketplace packs and the strats inside them get an upvote button (the details page of a strat
that came from a pack). One vote per install; the bot tallies them into the catalog, and "Top rated" sorts
by them. Your own strats have no vote button: only published ("original") strats can be voted on.

**Clips**: drop a video (mp4, webm, mov) on a step and the app turns it into a GIF right there, in the
browser: 10 frames a second, up to 8 seconds, 512 px wide, one 256-colour palette. It is stored as a
`.gif`, travels in packs as it is (GIFs are already compressed), and the overlay plays it like any other
picture. A clip can be held at a close-up (Permanent zoom) but never pulses. A `.gif` file is taken as is.

**Mid**: strats that are not post-plants (smokes, one-ways, flashes, recon, setups, entries, deny space)
can be placed at **Mid** as well as at a site.

**Settings** (the gear): which screen the overlay shows on, its size (a slider; the card and everything on
it scale together, and a running overlay restarts to apply it) and the screen corner it sits in.

**Feedback**: the Discord button's menu has "Send feedback": a text box that posts to a private channel
on the Stratlab Discord through a webhook set as `"feedback"` in `version.json`, with the app version and
a short install id attached.

**Display mode**: the overlay is a window on top of the game, so Valorant must run in **Windowed
Fullscreen** (Settings › Video › General › Display Mode). The app reads the game's own settings file and
shows an amber **Fullscreen** warning next to the Overlay button while the game is set to exclusive
Fullscreen.

## The app

**Stratlab** on your desktop (and in the Start menu) opens the app in its own window, no
console. Right-click the Start menu entry to pin it to the taskbar. The window is an Edge app
window; the backend is a tiny local server in `editor.ps1` (http://localhost:47821). The server
keeps running after the window closes, so the shortcut, the Start menu entry or a taskbar pin of
the window open instantly at any time. Launching again while it runs just opens another window.

While the server runs it shows a **tray icon** (the flame, in the notification area; Windows 11 may
tuck new icons under the ^ arrow, drag it out to keep it visible). Left-click opens the app; the menu
has **Overlay** (on/off), **Start with Windows** and **Quit Stratlab** (stops the overlay and the server).

A Startup-folder shortcut, **Stratlab (background)**, starts the server hidden at login
(`startup.vbs`, which runs `editor.ps1 -Background -AtLogin`). With **Start with Windows** off (tray
menu or the app's Settings, saved as `"autostart": false` in `config.json`) that run exits at once; the
shortcut itself stays so an update cannot turn the setting back on. `tools\install_shortcut.ps1`
rebuilds the icon and all shortcuts if they are lost.

The **Overlay** button in the header starts and stops the in-game overlay.

- **Home** opens with a welcome, rotating trash-talk quotes and your stats, over a random map's
  banner (blurred, tinted near-black, a new one each time the app opens). Below, agents are
  grouped by role, one compact bar each: portrait, name, and map chips with a count on each
  (ranked pool first, plus **All maps**). Click a chip to unfold that agent's strats as small
  cards grouped by site. Each card carries its first picture, title, a type tag, a utility tag
  (Molly, Smoke, Flash, Recon, Stun, Wall, Trap, Teleport...), the speed if marked, and a
  difficulty dot.
- **Search** matches every word against title, map, agent, site, ability, type, utility, speed
  and difficulty, so `flash`, `post plant`, `molly abyss` or `site b slow` all work. Matches
  unfold on their own.
- **+ New strat** walks through numbered steps, starting blank: the role (2x2 blocks), then one
  of that role's agents (over the role's key art); the map (ranked pool first); the **strat
  type** and the site; then the details. The step bar at the top jumps back to any step.
- **Strat types**: Post-plant and Entry (any agent), Optimal smokes (smokes and Cypher's cage),
  One-way (smokes, cages, walls), Flash, Recon, and Site setup (Sentinels only). A type the agent
  cannot use is greyed out, and the ability list then only offers the utility that fits it.
- **Details**: title, ability, difficulty; Attack / Defense for everything but post-plants; an
  optional speed (Fast, Moderate, Slow) for post-plants; and for Sova's Recon / Shock Bolt the
  **bounces** (0-2) and **charge** (0-3). Below that, the strat's **steps** as tabs over one
  large editor. Each type starts with its own steps (post-plant: Plant, Stand, Aim; site setup:
  Util 1-3; the rest: Stand, Aim, Result); rename any step, add up to 5, or remove one. Each
  step has an optional short **note** ("jump throw", "crouch"); "Overlay shows" previews the
  line the overlay will print, e.g. `Aim · jump throw · 1 bounce · 2 charge`.
  - Add pictures by dropping files, clicking the picture area, or taking a screenshot in game
    (Win+Shift+S) and pressing Ctrl+V. A paste goes to the open step if it is empty, otherwise
    to the first step without a picture, so pastes in a row fill the steps in order.
    PNG, JPG and WebP all work; pictures are scaled to 1280 wide on the way in.
  - **Every picture has its own zoom**: None, Pulse (zooms in and out) or Permanent (stays
    zoomed in). Drag the crosshair on the picture to aim it and set how far in with the slider.
    The window beside it shows the close-up exactly as the overlay will, pulsing on the
    overlay's rhythm when Pulse is chosen.
  - When a step has several pictures, **every picture has its own "Swap to next"**: how many
    seconds it shows before the next one.
- **Preview** plays the strat being edited in a replica of the in-game card (at 2x when the
  window allows): each picture's zoom and timing, crossfades within a step, cuts between steps.
  Left / Right change step, Esc closes. Unsaved pictures work too.
- **Save strat** (or Ctrl+S) writes the data and copies the pictures into `assets/`. A running
  overlay reloads within a couple of seconds. **Delete** asks first.

The app uses Inter (Google Fonts, with Segoe UI Variable as the offline fallback); the overlay
uses Bahnschrift, which ships with Windows.

## Packs (.stratlab)

Share strats as a single file:

- The **Packs** button in the header opens the Packs screen: **Export strats**, **Import**, and
  every pack as a tile on its main map's banner with its agents' portraits, the description, its
  maps, and **Open** (show only that pack on home, where a header adds **Show all**), **Edit**,
  **Export** and **Remove**.
- **Export strats** opens the pack builder: a tree of dropdowns on the left (agent > map > strats;
  a row opens or closes, its checkbox takes all of it), a type dropdown and a filter box, then the
  pack's name, description and author on the right. "Export these N" on an unfolded agent and a
  saved strat's Export button open the builder with those strats already picked. The file lands in
  Downloads. Pictures are re-encoded as JPEG (about 14x smaller than the original screenshots).
- **Packs are kept** (untick "Keep as a pack" for a one-off file). Re-exporting a kept pack keeps
  its identity, so whoever imports the new file gets updates instead of copies. Removing an
  imported pack removes its strats too; removing your own pack keeps the strats. Search matches
  pack names. Definitions live in `data/packs.json`.
- **Import**: the Import button in the header, or drop a `.stratlab` file (older `.lineuplab` packs work too) anywhere on the home
  page. A preview lists every strat and whether it is new or updates one you already imported
  from that pack; nothing changes until you press Import. Imported strats keep a link to their
  pack, so importing a newer copy of the same pack updates them instead of adding copies.
- **What a pack is**: a zip holding `manifest.json` (format, id, name, date), `strats.json` and
  `pics/`. Import accepts nothing else: every field is re-checked and rebuilt, every picture must
  decode as an image, sizes and counts are capped (60 MB pack, 8 MB picture, 200 strats), unknown
  agents or maps are refused. Nothing in a pack runs.

## The overlay

Use the **Overlay** button in the app, or double-click **Start Overlay.bat**. Either way it
starts silently through `overlay.vbs`.

In Valorant, set **Settings > Video > Display Mode** to **Windowed Fullscreen**. The overlay is
a normal window on top of the game; in exclusive Fullscreen the game draws over it.

It is a compact translucent card: the picture on the left, map and agent blocks and the option
(site + type, e.g. "B smokes"), strat and step rows beside it, and underneath the title, then
the step's name with its note (and a bolt's bounces / charge on the Aim step), with the
difficulty on the right and the speed stacked under it in its own blue. The panel is
**click-through**: the mouse passes straight to the game.

It stays **hidden until the map is known** (agent select). It then appears in the
**bottom-right corner**, and **moves to its configured spot once your agent is known**. It hides
again when the match ends or the game closes. The = key shows or hides it at any time; hiding it
by hand keeps it hidden until the next game.

### Controls

| Key | Action |
|---|---|
| Left / Right | previous / next step within the strat |
| Up / Down | next / previous strat (Up counts up) |
| \ | cycle the type blocks floating under the card (All, then each type this agent has on this map); Up then only walks that type |
| = | show / hide |
| Alt+arrows | nudge the panel 10px in that direction (saved) |
| (none) | the number keys are unbound: pick the screen with the app's Screen button; `nextOption` (next site), `nextAgent`, `nextMap`, `nextMonitor` can be set in `config.json` |
| Ctrl+Shift+Q | quit |

Every key is changeable in `config.json`. A key is a name like `5`, `F9`, `Left`, `Q`,
optionally with modifiers: `Ctrl+Shift+Q`, `Alt+8`. Keys only act while Valorant is the
foreground window; in every other app they behave normally. Bare keys also work while Shift
(walk) or Ctrl (crouch) is held.

### Map and agent detection

The map and agent blocks start blank. The map fills in when agent select opens, the agent once
you lock in, and both clear when the match ends. A green dot means the value came from the game.

1. **Riot's local client API** (the "lockfile" on this PC), asked read-only whether you are in
   agent select or a match, and which map and agent. This is the mechanism most fan tools use;
   it is not officially supported by Riot.
2. **Valorant's log file**, as a fallback for the map once the match has loaded.

Neither touches the game process. What detection saw is written to `detect.log`. Set
`"autoDetect": false` or `"autoShow": false` in `config.json` to turn either behaviour off
(with `autoShow` off the panel is simply always on screen).

### Pictures and zoom in the overlay

A step with several pictures cycles through them at the step's own swap time, with a short
crossfade; changing step is a plain cut. A picture with a zoom alternates between the full view
and its close-up, about two thirds of the time close up.

## config.json

| Field | Meaning |
|---|---|
| `monitor` | which screen the panel sits on, counting from 1 |
| `width` | panel width in pixels, default 372 |
| `anchor` | corner the panel hangs from once the agent is known: `top-right` (default), `top-left`, `bottom-left`, `bottom-right` |
| `offsetX`, `offsetY` | distance from that corner's edges (Alt+arrows adjust these) |
| `onlyInGame` | `true` to make keys act only while Valorant is in the foreground |
| `autoDetect` | `true` to detect map and agent |
| `autoShow` | `true` to hide in the menus and show from agent select on |
| `hotkeys` | the key bindings above |

## data/game.json

Every map and agent with its abilities, used by the app's pickers, plus:

- `ranked`: the competitive map pool, shown first. Currently Abyss, Ascent, Haven, Lotus,
  Split, Summit, Sunset (patch 13.04 swapped Breeze for Abyss). Edit it when the rotation
  changes.
- `sites`: which sites each map has (Haven and Lotus have a C).

## Strat format (data/lineups.json)

The app writes this for you; this is for reference.

```json
{
  "id": "sova-ascent-b-recon-1",
  "map": "Ascent", "agent": "Sova", "type": "recon", "site": "B", "option": "B recon", "side": "Attack",
  "ability": "Recon Bolt", "title": "Dart to clear B Site",
  "difficulty": "easy", "speed": "", "bounces": 1, "charge": 2,
  "steps": [
    { "type": "png", "src": "assets/x-stand-1.png", "label": "Stand", "notes": "crouch", "caption": "Stand: crouch" },
    { "type": "png", "src": ["assets/x-aim-1.png", "assets/x-aim-2.png"], "label": "Aim", "notes": "jump throw", "caption": "Aim: jump throw",
      "picZoom": [null, { "factor": 5.4, "x": 0.5, "y": 0.45, "mode": "hold" }], "picTime": [1.2, 3.0] }
  ]
}
```

- `type`: `post-plant`, `entry`, `smoke` (Optimal smokes), `one-way`, `flash`, `recon` or
  `setup` (site setup). `side`: `Attack`, `Defense` or `Both` (post-plants are always Attack).
- `difficulty`: `easy`, `intermediate` or `challenging`. `speed` (post-plants only): `fast`,
  `moderate` (formerly `average`), `slow` or empty. `bounces` / `charge`: bolts only, or null.
- `steps`: 1 to 5. `label` is the step's name and `notes` its short note, both shown in the
  overlay. Older strats have only a `caption` like "Plant: long how-to text"; the name is taken
  from it and the rest is kept but never shown.
- A one-picture step uses `zoom`; a several-picture step uses `picZoom` (one entry per picture,
  `null` for no zoom) and `picTime` (seconds each picture shows before the next). A zoom's
  `mode` is `pulse` (in and out) or `hold` (stays zoomed).

## Art

Map banners, agent portraits, ability and role icons are Riot's official art from
valorant-api.com, fetched by `tools/get_official_art.ps1`. Re-run it after a new map or agent
ships. Ability names in the data must match Riot's (`Shock Bolt`, not "Shock Dart").

## Files

- `editor.ps1`, `web/editor.html`, `launch.vbs`, `launch-bg.vbs` - the Stratlab app
- `overlay.ps1`, `overlay.vbs`, `Start Overlay.bat` - the in-game overlay
- `config.json` - overlay settings
- `data/lineups.json` - the strat library; `data/game.json` - maps, agents, abilities, pool
- `assets/` - pictures, map banners, icons; `assets/roles/` - role key art and the trophy art
- `tools/` - art download, shortcut installer, placeholder generator
