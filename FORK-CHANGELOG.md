# fenix-police — fork changelog

Changes made to this resource **downstream of upstream Fenix**.

Three documents, don't confuse them:

| File | Whose | What |
|---|---|---|
| `changelog.md` | Upstream Fenix | Original author's releases (1.0.0, 1.0.1). Do not edit. |
| `UPSTATE_PATCHES.md` | Yours | Technical record of local patches §1–13, written before this session |
| `FORK-CHANGELOG.md` | Yours | This file — everything changed in the ambient system since |

> Named `FORK-CHANGELOG.md` rather than `CHANGELOG.md` deliberately: Windows
> filesystems are case-insensitive, so `CHANGELOG.md` and the upstream
> `changelog.md` are the same file, and creating one would silently destroy the
> other.

## Why this file exists

Primarily as a **merge aid**: if you ever pull upstream fenix-police, this is the
list of what you'd lose, alongside `UPSTATE_PATCHES.md` §1–13.

On licensing — this is a personal-use build and is not distributed, so GPL-3
imposes nothing. Its obligations trigger on *conveying* the work, not on running
it; a server you run yourself, public or not, conveys nothing to anyone.

That changes the moment a copy leaves your hands — handed to another server
owner, pushed to a public repo, bundled into a server pack. Free distribution is
still distribution, and at that point this file doubles as the GPL-3 §5(a)
statement of changes it was originally written to be.

Separately, and regardless of distribution: **AGPL-3.0** code (FivePD-2.0,
FirstResponseMP) carries a network clause that would oblige offering source to
every player who connects. Nothing here is derived from those projects — see the
carjacking provenance note below.

---

## Unreleased — ambient enforcement

Builds on `UPSTATE_PATCHES.md` §11 (ambient presence) and §12 (em_toolkit
connector). Read those first for the base design.

### Added — um_fenix_bridge bundled as an optional companion

`um_fenix_bridge/` now ships inside this repo. It is a **copy** of the
standalone resource, not a move — the server still runs its own copy from
`[standalone]/um_fenix_bridge`, so the two can drift. Sync them when either
changes.

It is not loaded automatically. FiveM stops descending once a directory is
identified as a resource, so a nested resource is never discovered — the folder
is inert until copied out, which is what makes bundling safe here rather than
something that silently double-loads.

Bundled because it is the piece that makes this script respond to *scripted*
crime. Upstream's README asks you to hand-edit `qb-policejob` and
`qb-storerobbery` to fire `fenix:server:trigger`; the bridge instead listens for
alerts those resources already emit and maps them to wanted levels, so nothing
needs patching.

Only its `Crime` module is useful on a stock server, and it is the one with no
dependencies. `ERS` needs `night_ers`; `DynamicEvents` needs the private
`um_dynamicworld` and is off by default; `Witness` is off by default. Nothing in
it calls `exports` on another resource — every integration is an event listener,
so an absent resource never fires rather than erroring.

Licensed GPL-3.0 to match this repo.

### Added — radar speed enforcement

A new subsystem in `client/ambient.lua`. Ambient officers now read speed and
react, rather than being pure set dressing.

**Detection.** Sampled every `tickMs` (600 ms).

- Aimed radar traps watch a `detectRange` (60 m) cone of `coneDegrees` (70°) —
  cars behind the cruiser drive past untouched.
- Patrols and foot officers watch a plain `copDetectRange` (45 m) radius. Same
  function, called with `coneDegrees = 360`: `cos(180°)` is −1, so the cone test
  always passes and it degrades to a radius check.
- The player check walks the **path travelled since the last sample** in ~8 m
  steps, not just the current position, so detection has no speed ceiling. A
  300 m+ jump is treated as a teleport and skipped.
- Per-vehicle cooldown (`cooldownSeconds`, 45 s), with the cooldown table
  self-pruning each pass so it cannot grow across a session.

**Speed limits.** Posted limits are read from the `speedlimits` resource via two
exports added to its `client/main.lua` (`getSpeedLimitForStreet`,
`getSpeedLimitAtCoords`). Limits stay defined there; this resource only reads
them. Precedence:

1. A trap's authored "Enforced speed" from em_toolkit — overrides everything
2. Posted limit + `toleranceMph` (15)
3. `unpostedLimitMph` (80) where a street has no sign defined

Resolved once per tick from the driver's position, not per scene.

**Player response.** Hands off to this resource's own pursuit stack via
`ApplyWantedLevel` rather than growing a second one — two systems spawning
pursuit AI is exactly the overlap that keeps `sk_streetkings`' police module
disabled. An officer sat in a cruiser joins the chase; a **foot officer calls it
in** and lets the dispatch system send units.

The catching scene is flagged `enforcing` and exempted from the
`despawnWhenWanted` sweep, so it does not delete itself mid-catch and leave a
pursuit with no visible origin. It is given a `roamingLifetime` expiry at that
moment so it still cleans up, and `cullScenes` was moved above the wanted check
so that expiry is honoured while the player is wanted.

**NPC response.** No wanted system involved. Chase → yield
(`npcYieldSeconds`, 15 s) → roadside stop reusing the `stop` scene's look. The
NPC and its driver are **borrowed, not created**: held as mission entities for
the chase, then released via `SetPedAsNoLongerNeeded` /
`SetVehicleAsNoLongerNeeded` rather than deleted, since deleting them would blink
real traffic out in front of the player.

NPC pursuits stay with aimed traps by default (`catchNpcsFromAllCops = false`) —
every patrol chasing every speeding NPC becomes a permanent citywide car chase.

### Added — ambient carjackings

A sixth scene kind. A suspect walks up to a stopped car, drags the driver out
(`TaskEnterVehicle` flag 16), the victim flees on foot, and the suspect drives
off fast.

The getaway speed is chosen deliberately: fast enough that a radar trap down the
road will clock the suspect and give chase. A carjacking can therefore escalate
into a pursuit through the existing enforcement path, with no wiring between the
two features.

Runs as a state machine on the director's 1 s tick (no per-scene thread), with a
25 s timeout so an approach blocked by geometry can't freeze the scene.
`Config.Ambient.carjackSuspects` picks the ped list; `weights.carjack` (1)
controls how often it comes up.

**Provenance.** Concept reference only: FivePD-2.0's
`FivePD.Gamemode.IA.AmbientEvents` describes itself as handling "various ambient
events around players (e.x.: carjackings or speeders)" but ships as a stub —
class and init methods, no implementation. This was written from that one-line
description. **No code was taken from it.** That project is AGPL-3.0, whose §13
network clause would oblige offering full source to every player connecting to a
server running it — an obligation that applies even without distribution, which
is why concept-only was the route taken rather than porting.

### Fixed — Config.PoliceWantedProtection never worked

Pre-existing upstream bug, surfaced by radar enforcement applying wanted levels
to players. Two defects stacked in `client/client.lua`:

1. `isPlayerPoliceOfficer` is defined ~2250 lines below its use as a **file-scope
   local**, so the guards in `ApplyWantedLevel` and `SetWantedLevel` resolved a
   nil *global* instead.
2. Both guards read `and isPlayerPoliceOfficer` — **no call parens**. A function
   reference is always truthy.

(1) masked (2): nil is falsy, so the guard never fired and wanted levels were
always applied — including to on-duty officers. Fixing only the scoping would
have flipped it the other way and blocked wanted levels for *everyone*, so both
had to land together.

Fixed with a forward declaration near the top, the definition changed from
`local function` to plain assignment, and `()` added at both call sites. Player
police are now genuinely protected from every wanted level applied through this
resource's exports, not just from radar traps.

A separate loop (~line 2700) was clearing wanted levels from player cops each
cycle, which is why this never showed as more than a brief flicker.

### Added — enforcement exempts on-duty police

`Config.Ambient.radar.exemptPolice` (default `true`). Ambient officers skip
enforcement entirely against a player who is on duty as police, checked against
this resource's `Config.PoliceJobsToCheck` and against `night_ers`' shift state
— either sufficient, both behind `pcall`.

This is deliberately checked *before* a pursuit starts, rather than relying on
the wanted level being blocked once a chase is already underway.

`night_ers` owns player-side police RP on this server. An ambient trap chasing an
on-duty officer to a call is the kind of crossover that makes AI police read as
broken rather than alive.

New export: `exports['fenix-police']:IsPlayerPoliceOfficer()`, so `ambient.lua`
can reach the check from a different file.

### Added — placement quality

Replaced first-fit road-node selection with scored sampling. `bestRoadNode`
samples `nodeSamples` (10) candidates and **rejects** any that:

- is occupied — `IsPositionOccupied` over a 3.5 m sphere, which stops scenes
  materialising inside moving traffic
- sits on a node with traffic density ≤ 1 (dirt tracks, dead ends) — the source
  of "spawned in the middle of nowhere"
- is within `minSceneSpacing` (90 m) of a live scene — anti-clump
- is currently visible to the player (`avoidVisibleSpawns`) — no pop-in

Survivors are scored, favouring mid-band distance and higher-density streets, and
penalising junction nodes by 25 points because a scene parked in the box blocks
real traffic.

Static scenes (radar traps, traffic stops) are pushed `shoulderOffset` (4.5 m)
onto the verge. Patrol and pursuit still spawn on the carriageway — they drive
off immediately, so a verge offset would beach them.

`radarFallbackToRoadNodes` is now **off by default**. It invented radar traps at
random road nodes whenever no authored point was in range, and was the single
largest source of "there are cops everywhere".

### Added — officer budget

`maxScenes` alone is a poor cap: two 4-officer foot posts is 8 officers in two
scenes. Added `maxNearbyCops` (6) within `nearbyRadius` (260 m).

Costs **one integer per scene** (`scene.cops`). The total is computed inside
`cullScenes`, which already walks every scene and computes each one's reference
position — it now returns the count instead of discarding that work. No world
scans, no extra threads, no per-frame cost.

### Changed — authored points are used verbatim

Three mechanisms were relocating hand-placed points before anything spawned:

| Mechanism | Displacement |
|---|---|
| `snapToRoad` → nearest vehicle node | up to **120 m** (`snapRadius`) |
| Radar shoulder offset + heading flip | 4.5 m sideways, **180°** rotation |
| `GetSafeCoordForPed` on foot posts | up to **25 m** |

All three exist because `data/ambient_points.lua` is explicitly approximate.
Applied to a point captured by standing on the spot, they are noise.

Candidates now carry an `exact` flag, set for points arriving from em_toolkit.
Exact points skip snapping, the shoulder offset and the heading flip entirely —
a radar cruiser spawns exactly where it was parked, facing exactly how it was
parked. Shipped seeds keep the original behaviour. `snapToRoad`'s config comment
was rewritten to say so.

### Changed — per-trap vehicle and enforced speed

`spawnRadar` honours `vehicle` and `speed` fields on an authored point, falling
back to the regional vehicle list and the config-wide trigger speed when absent.
If an authored model fails to load (never streamed, addon removed) it logs and
falls back rather than losing the trap.

### Fixed — traffic stops never ended

`spawnStop` set no `expiresAt` at all. Patrol and pursuit did; stops did not. A
traffic stop was therefore **permanent**, held only by the distance cull — an
officer standing with a clipboard until the player walked far enough away. This
predates the radar work.

Added a shared wind-down used by both procedural stops and radar-caught NPCs:

`dwelling` (`stopDurationSeconds`, 60 s) → `wrapping` (officer walks back via
`TaskEnterVehicle`, 16 s timeout so a walk-back snagged on geometry cannot wedge
it) → `leaving` (sirens off, both drivers get `TaskVehicleDriveWander`) → scene
expires `stopDepartureSeconds` (25 s) later.

Departed scenes are flagged `releaseOnTeardown`; `destroyScene` then hands every
ped and vehicle to the population manager instead of deleting them, so the cars
you just watched pull away do not blink out moments later.

A scene conducting a stop is excluded from the armed list — its officer is out of
the vehicle and has no business starting a second pursuit.

### Fixed — enforcement aborted silently on every catch

`string.format('%d', x)` raises `number has no integer representation` on
Lua 5.3+ when `x` is fractional. `speedMph` is `GetEntitySpeed() * 2.236936` —
always a float.

The throw occurred on the first line of `catchPlayer`, **after**:

```lua
startCooldown(veh)      -- vehicle: 45s cooldown
scene.enforcing = true  -- officer: permanently disarmed
```

and **before** `ApplyWantedLevel`. Every catch detected the speeder correctly,
marked itself as having acted, put the vehicle on cooldown, and died. The
surrounding `pcall` reported it as `[FENIX-AMBIENT] radar error:` and nothing
reached the player.

Every `%d` receiving a measurement is now `%.0f`.

### Fixed — leftover debug logging in `server/server.lua`

`GetWantedLevelFromCoords` ran three unconditional `print` calls per configured
location on **every alert**, two of them concatenating `vector3` values onto
strings with `..` — not a supported operation on that type.

Gated behind `Config.isDebug` and routed through `tostring()`.

### Changed — `Config.Ambient.debug` returned to `false`

It was switched on during diagnosis and prints to every client console.

---

## Config reference — new keys

All under `Config.Ambient`.

### Placement

| Key | Default | Purpose |
|---|---|---|
| `weights.carjack` | `1` | How often a carjacking comes up |
| `carjackSuspects` | 5 peds | Ped list for carjackers; falls back to `civPeds` |
| `nodeSamples` | `10` | Candidate road nodes scored per spawn attempt |
| `minSceneSpacing` | `90.0` | Minimum distance between two live scenes |
| `maxNearbyCops` | `6` | Officer ceiling within `nearbyRadius` |
| `nearbyRadius` | `260.0` | Radius the officer budget counts over |
| `shoulderOffset` | `4.5` | How far static scenes sit off the driving line |
| `avoidVisibleSpawns` | `true` | Never spawn a procedural scene on screen |
| `radarFallbackToRoadNodes` | `false` | Invent traps where no point is authored |

### Traffic stops

| Key | Default | Purpose |
|---|---|---|
| `stopDurationSeconds` | `60` | How long a stop runs before the officer wraps up |
| `stopDepartureSeconds` | `25` | Grace after departure before teardown |

### `Config.Ambient.radar`

| Key | Default | Purpose |
|---|---|---|
| `enabled` | `true` | Master switch for enforcement |
| `enforceFromAllCops` | `true` | All officers enforce, not just aimed traps |
| `usePostedLimits` | `true` | Read limits from the `speedlimits` resource |
| `toleranceMph` | `15` | Grace over the posted sign |
| `unpostedLimitMph` | `80` | Applies where no sign is defined |
| `triggerSpeedMph` | `60` | Fallback when posted limits are off/unavailable |
| `detectRange` | `60.0` | Aimed trap range |
| `coneDegrees` | `70.0` | Aimed trap cone, full width |
| `copDetectRange` | `45.0` | Patrol / foot officer radius |
| `tickMs` | `600` | Sampling interval |
| `npcScanEveryTicks` | `2` | Walk the vehicle pool every N ticks |
| `cooldownSeconds` | `45` | Per-vehicle re-clock lockout |
| `catchPlayers` | `true` | Enforce against players |
| `exemptPolice` | `true` | Never enforce against on-duty player police |
| `playerWantedLevel` | `1` | Stars applied on a catch |
| `catchNpcs` | `true` | Enforce against NPC traffic |
| `npcYieldSeconds` | `15` | Chase length before the NPC pulls over |
| `catchNpcsFromAllCops` | `false` | Let patrols pull NPCs over too |

---

## Commands

| Command | Purpose |
|---|---|
| `/ambientpolice [on\|off]` | Toggle ambient. Now also lists live scenes with distances, arm state and the limit applying where you stand. **Bare form toggles** — pass `on` explicitly. |
| `/ambientpolicereload` | Re-read em_toolkit points, clear scenes |
| `/radartrace` | Per-second trace of the enforcement decision: tick state, speed vs allowed, and per-scene distance / reach / seen |

---

## Files changed

| File | Scope |
|---|---|
| `client/ambient.lua` | Heavy — placement scoring, officer budget, radar enforcement, stop lifecycle, diagnostics |
| `config.lua` | `Config.Ambient` placement/radar/stop keys; `debug` back to `false`; `snapToRoad` comment |
| `server/server.lua` | Debug logging in `GetWantedLevelFromCoords` gated and made type-safe |

External dependency added: `speedlimits/client/main.lua` gained two exports.
That resource is MIT (© 2022 Sinatra) and separately licensed.

---

## Known limitations

- **NPC detection is position-only.** The player check is path-swept, NPCs are
  not — per-vehicle position history would mean per-entity state. NPC traffic
  rarely exceeds ~80 mph, so this is academic, but a genuinely fast NPC can slip
  through.
- **"Any cop" means any officer this ambient system spawned.** Police peds from
  other resources are not included. Reaching into other resources' entities is
  the overlap problem that keeps `sk_streetkings`' police module disabled.
- **Enforcement filters stack.** Spacing, the officer budget, occupancy and
  visibility checks together make ambient noticeably sparser than before. If it
  overshoots, loosen in this order: `radarFallbackToRoadNodes` → `minSceneSpacing`
  → `maxNearbyCops`.
- **Largely unplayed.** The stop wind-down, the NPC yield sequence, all-officer
  enforcement and ambient carjackings are written and statically verified but
  were never observed running. Timings in particular will want tuning — the
  carjack approach window (25 s), the NPC yield delay (15 s) and the stop dwell
  (60 s) are all first guesses.
- **Carjack → pursuit is emergent, not wired.** The getaway is driven fast
  enough that a radar trap should clock the suspect, but nothing guarantees a
  trap is in range. If you want carjackings to reliably draw a response, that
  needs an explicit hook rather than the current happy accident.
