# Upstate Mafia local patches to fenix-police

> If you `git pull` to update fenix-police, these changes will be overwritten.
> Re-apply them or reconcile via merge.

> **§1–13 below are the patches as of the ambient-presence work.** Everything
> changed since — placement scoring, the officer budget, radar speed
> enforcement, the traffic-stop lifecycle, and the bug fixes that came with
> them — is in [`FORK-CHANGELOG.md`](FORK-CHANGELOG.md), which also carries the
> GPL-3.0 §5(a) statement of changes. Read §11 and §12 here first for the base
> design those changes build on.

## 1. Police job list expanded (config.lua)

Added `bcso` and `sasp` to `Config.PoliceJobsToCheck` so that BCSO and SASP officers:
- Count toward "online police" headcount (suppresses AI dispatch when on duty)
- Are protected from getting wanted levels when `Config.PoliceWantedProtection = true`

Matches the `inventory:police` job list in [ox.cfg](../../../ox.cfg).

## 2. Death detection made framework-agnostic (client/client.lua ~line 2021)

**Before:**
```lua
if QBCore.Functions.GetPlayerData().metadata['isdead']
   or QBCore.Functions.GetPlayerData().metadata['inlaststand'] then
```

**Problem:** wasabi_ambulance (your current EMS) does not set `metadata.isdead` or
`metadata.inlaststand`. Original code only worked with qb-ambulancejob /
qbx_ambulancejob. Dead players never had their wanted level cleared.

**After:** uses native `IsEntityDead` + `IsPedFatallyInjured` (works regardless of
EMS resource), with the original metadata check kept as a fallback for anyone
running an ambulance script that does set those keys.

## Files backed up

- `client/client.lua.bak`
- `config.lua.bak`

To restore originals: rename `*.bak` files back over the patched ones.

## 3. Wanted level kept enabled when AI dispatch is off (client/client.lua ~line 1898)

**Before:**
```lua
SetMaxWantedLevel(0) -- Disable wanted level
```
(inside the `disableAIPolice == true` branch of `UpdateDispatchServices`)

**Problem:** When a player cop went on duty, fenix would clamp the max wanted level
to 0. This meant killing peds raised no wanted stars, the minimap had no indicator,
and ps-dispatch never alerted player cops to crimes in progress. Defeats the
purpose of having player cops respond.

**After:** `SetMaxWantedLevel(5)` — wanted level system stays alive regardless of
whether fenix is dispatching AI cops. AI dispatch is still gated by
`disableAIPolice` so player cops handle pursuits, but the wanted level itself
(and all the systems that read it) now works.

## 4. Vehicle spawn pool rebalanced for all regions (config.lua)

**Before:** `riot` (prison van) had `wantedLevel = 3, spawnChance = 10` in paletoBay,
sandyShores, and countryside — making it ~43% of all spawns at wanted 3.
FBI vehicles had `spawnChance = 15` each.

**After (all four regions):**
- `policet` (police transporter) removed entirely
- `riot` moved to `wantedLevel = 5, spawnChance = 3` — only at max wanted
- Patrol/sheriff vehicles boosted to `spawnChance = 5` (or 4-8 for countryside rangers)
- FBI vehicles reduced to `spawnChance = 5`
- Net result: wanted 1-4 spawns are patrol cars and sheriffs; riot + FBI at wanted 5

## 5. Heli spawn handler — same seating + door unlock fix (server/server.lua)

Applied the same three fixes from the ground unit handler (patch in previous session)
to `spawnPoliceHeliNet`:

1. **Door unlock + statebag**: `SetVehicleDoorsLocked(vehicle, 1)` and
   `Entity(vehicle).state:set('doorslockstate', 1, true)` after heli creation
2. **Spawn peds at vehicle**: Changed from `spawnPoint.x+20, spawnPoint.y+20` to
   `spawnPoint.x, spawnPoint.y, spawnPoint.z + 1.0`
3. **Reliable seating**: Replaced nested `TaskWarpPedIntoVehicle` retry loop with
   `SetPedIntoVehicle` (instant) → `TaskWarpPedIntoVehicle` fallback, up to 20 attempts
4. **500ms vehicle init wait** before attempting to seat peds

## 6. Cops always hostile when player is wanted (client/client.lua)

**Before:** Cops spawned with `accuracy = 0`, drive-by disabled, and only entered combat
mode when `IsPedShooting(playerPed)` was true on a specific frame. Cops would drive up
and stand next to wanted players doing absolutely nothing.

**After:** All combat attributes enabled on spawn (accuracy 15-40, drive-by, cover, etc.).
Drivers immediately `TaskVehicleChase` with PIT/boxing. Passengers immediately
`TaskCombatPed`. The `playerHasShot` gate was removed from all three chase behavior
functions (ground, heli, air) — cops are always aggressive when the player has a wanted
level, matching vanilla GTA behavior.

## 7. Surrender & arrest system (config.lua + client/client.lua)

**New feature:** Press **H** to surrender (hands up). Nearby officers stop shooting,
approach with weapons aimed. The closest officer walks up to arrest. When within 2m,
a cinematic **BUSTED** screen plays (identical to the WASTED screen but red "BUSTED"
text), with slow-motion, camera pull-back, screen desaturation, and sound. After the
sequence, the player is teleported to the nearest police station with wanted level
cleared.

Config block: `Config.ArrestSystem` — toggle on/off, arrest distance, BUSTED duration,
subtitle text, and list of station respawn coords.

## 8. Entity control + weapon reliability fix (client/client.lua — all spawn handlers)

**Before:** Client-side `GiveWeaponToPed`, `TaskVehicleChase`, `TaskCombatPed`, `SetPedCombatAttributes`
etc. were called without first requesting entity control from the network layer.
Server-spawned entities are server-owned; without `NetworkRequestControlOfNetworkId`,
all modification calls silently fail — cops spawn unarmed (punching) and don't chase.

Also: `SetBlockingOfNonTemporaryEvents(officer, true)` was preventing cops from engaging
combat AI, and `SetNetworkIdCanMigrate(id, false)` locked entities to the server,
preventing the client from gaining control.

**After:**
- Every spawn handler (ground, heli, air) calls `NetworkRequestControlOfNetworkId` + waits
  for control before modifying the ped
- `SetNetworkIdCanMigrate` changed to `true` so control can migrate to the client
- `SetBlockingOfNonTemporaryEvents` removed entirely
- `SetCurrentPedWeapon` called after `GiveWeaponToPed` to force equip
- `SetPedRelationshipGroupHash(officer, 'HATES_PLAYER')` added so cops treat player as enemy
- `handleChaseBehavior` re-checks entity control and re-arms unarmed cops every tick
- Firing pattern hash corrected to `0xC6EE6B4C` (FIRING_PATTERN_FULL_AUTO)
- Surrender animation changed to `random@mugging3` / `handsup_standing_base` (more reliable)
- `SetVehicleModelIsSuppressed('policet', true)` added globally to prevent ambient spawns

## 9. Cops-online check loop delay fixed (server/server.lua)

Moved the `Wait(5000)` that was sitting between polCount calculation and the
`TriggerClientEvent` broadcast to before the `while true` loop, per the note this
file already had flagging it. It's now a one-time startup delay instead of an
extra 5s tacked onto every 60s cycle.

## 10. Combat scaled by wanted level (config.lua + client/client.lua + server/server.lua)

**Problem:** Patch #6 above swung too far. Every officer spawned with accuracy
25-50, `FIRING_PATTERN_FULL_AUTO`, drive-bys on, `HATES_PLAYER` and an immediate
`TaskCombatPed`. A 1-star chase was an instant firefight with pinpoint-accurate
cops — the opposite problem from cops standing around doing nothing.

**New config block: `Config.Combat`.** Everything below is tunable there; set
`Config.Combat.enabled = false` to restore the patch-#6 always-hostile behaviour.

Defaults now shipped:

| Wanted | Open fire? | Accuracy | Shoot rate | Combat ability | Drive-bys | Pattern |
|--------|-----------|----------|-----------|----------------|-----------|---------|
| 1 | never | 5-10 | 25 | poor | no | burst |
| 2 | never | 6-12 | 35 | poor | no | burst |
| 3 | ~25% of officers | 8-16 | 50 | poor | no | burst |
| 4 | always | 14-25 | 120 | average | yes | burst |
| 5 | always | 20-32 | 200 | professional | yes | full auto |

So wanted 1-3 is a **pursuit** (sirens, PIT, boxing) and wanted 4-5 is a
**shootout**.

How the hold-fire actually works — three levers, because any one alone leaks:

1. **No combat task.** Passengers below the threshold get no `TaskCombatPed` at
   all, and are moved to a `'Standby'` task state instead of `'CombatPed'`. If
   they were already fighting and the level drops, `ClearPedTasks` de-escalates
   them.
2. **Relationship group.** Non-hostile officers go into a runtime-created
   `FENIX_PURSUIT` group set to Respect toward `PLAYER`, so they will not start a
   fight on their own initiative. `COP` is deliberately *not* used for this — the
   base game rewires COP/PLAYER dynamically off the wanted level, so it is not a
   stable "don't shoot" state. Officers flip to `HATES_PLAYER` when hostile.
3. **Combat attribute 46 (AlwaysFight)** is off below the threshold, and
   attribute 2 (CanDoDrivebys) is off below `drivebyFromLevel`. Drive-bys were
   the main source of getting shot through the windshield at speed.

**Provocation escalation.** If the player fires a weapon or damages any officer
(`IsPedShooting` in the main loop, `HasEntityBeenDamagedByEntity` per officer per
cycle), *every* unit escalates to full hostility — hostile group, drive-bys, full
auto — for `Config.Combat.provokedDuration` (30s default), regardless of wanted
level. Cops still defend themselves at 1 star; they just don't start it. The
timer resets to 0 when the wanted level clears.

**Engage roll is sticky.** At wanted 3 the ~25% "will this officer shoot" roll
happens once per officer at spawn and is stored in `vehicleData.officerEngage`,
so a unit doesn't flicker between shooting and not shooting every cycle. Ground
units carry the flag from spawn; heli/air units roll lazily on first cycle.

**Applies to ground, heli and air units.** Ground crews are client-spawned so the
profile is set in `fenix-police:spawnPoliceUnitClient`; heli/air crews are
server-spawned so `server.lua` has a mirror helper that sets the initial profile,
with the client re-applying the full profile (including relationship group and
provocation) every cycle in the three `handle*ChaseBehavior` functions.

`SetPedShootRate` / `SetPedCombatAbility` are called behind existence checks on
the server — neither is used elsewhere server-side in this resource, and a
nil-call there would take down the whole server script.

## 11. Ambient police presence (new: config.lua, data/ambient_points.lua, client/ambient.lua)

**Problem:** the main loop calls `SetCreateRandomCops(false)` /
`SetCreateRandomCopsNotOnScenarios(false)` / `SetCreateRandomCopsOnScenarios(false)`
every cycle so base-game ambient cops don't fight the dispatch system. Correct,
but it also strips every cop off the map outside a chase — no patrols, no
stations with anyone in them, no traffic stops.

**New `client/ambient.lua`** puts them back under script control. Five scene
kinds, weighted in `Config.Ambient.weights`:

| Kind | Source | What it is |
|---|---|---|
| `radar` | fixed point | Cruiser on the shoulder facing oncoming traffic, officer inside |
| `post` | fixed point | Officers on foot at a station/landmark playing scenarios |
| `stop` | procedural | NPC pulled over, cruiser behind with muted lights, officer writing at the window |
| `patrol` | procedural | Cruiser driving a normal route, no siren |
| `pursuit` | procedural | NPC vehicle fleeing, 1-2 cruisers chasing with sirens |

Design notes:

- **Fully decoupled from the pursuit system.** Shares no state with
  `client/client.lua`; only reads `GetPlayerWantedLevel`. Every scene is torn
  down the moment a wanted level appears (`despawnWhenWanted`), so ambient units
  can never get tangled in a real chase.
- **Client-local, non-networked entities**, like a map prop —
  `CreatePed(..., false, false)` plus `SetEntityAsMissionEntity` so the
  population manager doesn't cull them mid-scene. No net IDs, no server
  round-trips, none of the ownership races the pursuit spawner had to fight.
  Fixed-point scenes use the same coordinate list on every client so everyone
  sees the same scene in the same place; roaming scenes differ per client.
- **Ambient officers are dressing, not combatants.** They go in a runtime
  `FENIX_AMBIENT` relationship group set to Respect toward `PLAYER`, armed but
  at ambient-tier accuracy. Shoot one and normal ped reactions plus the wanted
  system take over.
- **Budgeted**: `maxScenes` (4) live at once, spawned 70-220m out, deleted past
  320m; roaming scenes also expire after `roamingLifetime` so patrols and
  pursuits keep cycling rather than trailing you forever.

**Seed coordinates in `data/ambient_points.lua` are approximate on purpose.**
`radar` points snap to the nearest vehicle node (rejected if the nearest road is
over `snapRadius` away, and radar falls back to any nearby road node so the
scene still appears in uncovered areas); `post` points snap to ground via
`GetSafeCoordForPed`. The `post` list uses the exact station coordinates already
in `Config.ArrestSystem.stations`.

Commands: `/ambientpolice [on|off]` toggles it live, `/ambientpolicereload`
re-reads toolkit points and clears scenes.

## 12. em_toolkit connector for police points (em_toolkit resource)

`em_toolkit/client/police.lua` + `server/police.lua`, reachable from
**World & Environment -> Police Scenarios**. Park or stand where you want a
scene, capture the spot, and it's saved to `em_toolkit/data/police_points.json`
and synced to everyone. Includes a marker overlay with heading arrows, plus
teleport / move / delete per point.

The connector stores coordinates and nothing else — it spawns nothing.
fenix-police reads them through `exports['em_toolkit']:getPolicePoints()` behind
a `pcall`, and re-reads on the `em_toolkit:policePointsChanged` event. With
em_toolkit absent or stopped, fenix-police runs off its own shipped list;
set `Config.Ambient.useToolkitPoints = false` to ignore the connector entirely.

Only `radar` and `post` are placeable, because those are the only kinds that use
fixed points — `stop` / `patrol` / `pursuit` pick road nodes at runtime.

## 13. Combat numbers re-anchored to Rockstar's own difficulty tiers

Source: [calamity-inc/GTA-V-Decompiled-Scripts](https://github.com/calamity-inc/GTA-V-Decompiled-Scripts),
`decompiled_scripts/fm_content_vehrob_police.c`. Helpers `func_311` / `func_312`
/ `func_313` are applied together on every enemy ped (~line 12076) and switch on
a difficulty field:

| Rockstar tier | accuracy | shootRate | combatAbility |
|---|---|---|---|
| 2 "easy" | 10 | 60 | 1 |
| 3 "normal" | 25 | 80 | 2 |
| 4 "hard" | 40 | 100 | 2 |

(Peds carrying an RPG or railgun are dropped to accuracy 2.)

Corrections applied to patch #10's guesses:

- **shootRate was far too high.** Patch #10 used 120 at wanted 4 and 200 at
  wanted 5. The native takes up to 1000, but Rockstar never exceeds **100** —
  so those values were hotter than the hardest enemies the base game ships.
  Now 30/40/50/80/100, with wanted 4 = their "normal" and wanted 5 = their "hard".
- **combatAbility floor raised from 0 to 1.** Rockstar never uses 0 (poor).
  Ability affects movement, cover and reaction time, so 0 reads as broken rather
  than merely less dangerous. Now 1/1/1/1/2.
- **accuracy nudged onto their tiers**: wanted 4 ceiling 25 ("normal"),
  wanted 5 ceiling 40 ("hard"). Wanted 1-3 stay at or below "easy".
- **Combat attribute 24 is now cleared** on every officer. The base game clears
  it in the same block where it sets an explicit `SET_PED_SHOOT_RATE`, so it
  doesn't fight the rate being set.
- **Air crews get `FIRING_PATTERN_BURST_FIRE_HELI`** (hash `0x914E786F`, seen as
  the literal `-1857128337`). In the base game it's set in the same block as
  combat attributes 52/53/89 for peds on mounted vehicle weapons — which is
  exactly the setup our heli/air units already run. New config key
  `Config.Combat.firingPatternHeli`; both the client profile and the server
  mirror take a `role` argument and all three server call sites (heli pilot,
  heli crew, air pilot) pass `'air'`.

Also verified against the same source: `FIRING_PATTERN_BURST_FIRE` is a real
base-game pattern name, and `WORLD_HUMAN_COP_IDLES` / `WORLD_HUMAN_GUARD_STAND`
are what the base game uses for cops standing guard around a police vehicle —
both now lead `Config.Ambient.footScenarios`, alongside other scenario names
confirmed in use (`STAND_IMPATIENT`, `STAND_MOBILE`, `INSPECT_STAND`, `LEANING`,
`SMOKING`, `DRINKING`).

## Files NOT modified

- `client/VANILLAclient.lua` — not loaded by fxmanifest, dead weight. Safe to delete.

## Framework compatibility note

`QBCore = exports['qb-core']:GetCoreObject()` in client/client.lua and
server/server.lua looked broken at first glance (no literal `qb-core` resource
exists on this server), but it isn't: `qbx_core` declares `provide 'qb-core'`
and ships a full compat bridge (`bridge/qb/`) active by default
(`qbx:enablebridge` convar defaults to `'true'`, not disabled anywhere in
server.cfg). Every specific call this resource makes —
`GetPlayerData()`, `GetVehicles()`, `GetClosestVehicle()`, `Notify()`,
`GetQBPlayers()` — is implemented in that bridge with matching signatures
(confirmed by reading `qbx_core/bridge/qb/client/functions.lua` and
`server/functions.lua` directly). No rewrite needed.
