<img src="img/FenixPolice001.jpg" alt="Fenix Police Response" width="800"/>

# Fenix Police Response 2.0 — Upstate Mafia Fork

AI police dispatch and wanted levels for FiveM, replacing the base GTA V police
system with something less punishing and more deliberate. Every setting is
configurable and the code is thoroughly commented to make end-user modification
practical.

> **This is a fork.** The original is
> [FenixPK/fenix-police](https://github.com/FenixPK/fenix-police) by **Fenix**,
> who wrote everything this is built on. This fork tracks upstream 1.0.2 and adds
> an ambient enforcement layer on top. Version 2.0 is *this fork's* number and
> has no relationship to upstream's versioning.
>
> Licensed **GPL-3.0**, same as upstream. `FORK-CHANGELOG.md` and
> `UPSTATE_PATCHES.md` together are the GPL-3 §5(a) statement of changes.

---

## Contents

1. [What this fork adds](#what-this-fork-adds)
2. [Project status](#project-status)
3. [Features](#features)
4. [Requirements](#requirements)
5. [Installation](#installation)
6. [Exports](#exports)
7. [Bundled — um_fenix_bridge](#bundled--um_fenix_bridge)
8. [Optional — posted speed limits](#optional--posted-speed-limits)
9. [Commands](#commands)
10. [Credits](#credits)
11. [Licence](#licence)

---

## What this fork adds

Upstream spawns police in response to a wanted level. This fork adds police who
are *already there* — and who react.

### Radar speed enforcement

Ambient officers read speed and act on it, rather than being set dressing.

- Aimed radar traps watch a **60 m / 70° cone**, so traffic behind the cruiser
  drives past untouched. Patrols and foot officers use a plain **45 m radius**.
- Player detection **walks the path travelled since the last sample** in ~8 m
  steps rather than checking current position, so there is no speed at which you
  outrun the check. A 300 m+ jump is treated as a teleport and skipped.
- Posted limits come from the optional [`speedlimits`](#optional--posted-speed-limits)
  resource, falling back to a configurable unposted limit.
- Caught players are handed to this resource's **existing** pursuit stack via
  `ApplyWantedLevel` rather than a second parallel one. Caught NPCs get a chase,
  a yield, and a roadside stop, with no wanted system involved.

### Roadside citations

Getting caught speeding used to have one ending: hands up, BUSTED screen, wake
up at a station with whatever you were driving to abandoned. Now the surrender
key does something different when you're behind the wheel at a low wanted level.

- Press it while driving and you signal a stop — hazards on, the pursuit stops
  re-tasking, and the nearest unit pulls in behind you once you've stopped.
- One officer walks to your **driver's window** (no weapon drawn — a citation at
  gunpoint is an arrest with extra steps), writes for a few seconds, and hands it
  over. You keep your car, your position and your route; the fine is the cost.
- The fine is priced and charged **server-side** from `Config.TicketSystem.fine`.
  The client reports that a stop completed and at what wanted level, never what
  it is willing to pay, and the level is clamped before it indexes the amounts.
- Can't afford it? It goes on record unpaid and you still drive away. Turning
  "you're broke" into a teleport to a station is the outcome this exists to avoid.
- Take off again after stopping, fire on police, or escalate past
  `maxWantedLevel` (1 star by default — a genuine traffic offence) and the stop
  is off; the pursuit picks straight back up.

The radar trap that clocked you stands its own car down when a stop starts,
rather than PITting a vehicle that has already pulled over.

### Weighted vehicle selection

`Config.Ambient.vehicles` accepts a `model = weight` map per region as well as
the original flat array. Weights are how you get one agency dominant in a region
while another still turns up occasionally — a county sheriff carrying Blaine
County but appearing in the city now and then, a highway patrol present
everywhere at a steady rate — without hard-coded region rules.

It ships with **base-game models only**, so it works on any server. Point it at
add-on liveries and the safety net holds: a model that isn't installed is skipped
when the pick is *rolled* rather than failing the spawn, so a mixed list degrades
to whatever that client actually has, and a region that resolves to nothing falls
through to `vehicleFallback` — stock `police` / `sheriff`.

### Ambient carjackings

A suspect drags a driver out of a stopped car and speeds off. The getaway speed
is chosen so a radar trap down the road will clock them — a carjacking can
escalate into a full pursuit through the existing enforcement path, with no
wiring between the two features.

### On-duty police are exempt

Checked *before* a pursuit starts rather than relying on the wanted level being
blocked mid-chase. Honours both this resource's `Config.PoliceJobsToCheck` and
`night_ers` shift state.

### Placement quality

First-fit road-node selection replaced with scored sampling that rejects
occupied positions, low-traffic nodes (the source of "spawned in the middle of
nowhere"), anything within 90 m of a live scene, and anything currently visible
to the player. Static scenes are pushed onto the verge; patrols stay on the
carriageway because they drive off immediately.

`radarFallbackToRoadNodes` now defaults **off** — it invented traps at random
nodes and was the single largest source of "there are cops everywhere".

### Encounter rate, and the convoy scene

`spawnInterval`, `maxScenes`, `maxNearbyCops` and `minSceneSpacing` are all
tuned down from their original defaults — a cop on 7 out of 10 corners was the
reported experience, and the first three of those in particular are what
control how fast an empty scene slot gets refilled, not just how many exist at
once.

Two or three cruisers occasionally seen driving together with no lights on is
now a real scene (`convoy`) instead of an accident of independent patrols
drifting together on the same road. Two cars normally, three sometimes, on
their own cooldown so it stays a sight rather than the new normal. See
`Config.Ambient.convoy*` in `config.lua`.

### Lane-correct placement and airside no-go zones

Both spawners now go through `client/roads.lua`, which resolves a candidate
point to a real road with `GET_CLOSEST_ROAD` and reads the lane count in each
direction — the one thing the vehicle-node natives don't report, and the reason
units used to appear facing oncoming traffic. A vehicle node is the *centre line*
of a road, not a lane, and the heading it reports is only one of the road's two
legal directions of travel. Placing a car on that data straddles the paint and
points the wrong way roughly half the time.

With the lane counts in hand, placement computes an actual lane centre and picks
a direction the road permits, so a one-way street can no longer be entered
backwards no matter where the player is. Facing the player is scored as a
preference, never enforced — enforcing it is what produced the wrong-way spawns
in the first place.

`Config.Roads.exclusionZones` keeps units off LSIA and Fort Zancudo airside. It
does two separate jobs: candidate points inside a zone are rejected, and
`SET_ROADS_IN_AREA` switches the AI road network off there, which is what stops a
pursuit that started on a normal street from routing down the active runway.
Spawn rejection alone cannot do that. Backing it up everywhere else, a candidate
on a surface the game gives no street name to — runway, apron, car park aisle,
dirt scrape — is rejected outright, which needs no coordinates to maintain.

The shipped zones are hand-measured boxes. Draw them with `/fenixroads` and check
a spot with `/fenixroads here` before trusting them, and trim them in
`config.local/` so an update doesn't overwrite your work.

### Server-side entity security

Every mutating net event took a network ID straight off the wire and acted on
whatever it resolved to — delete any entity, unlock any vehicle, arm any ped
including a player's. Network IDs are small integers, so none of that needed
guessing, only counting. `server/guard.lua` gates all of them behind three
layers:

1. **A player's ped, or a vehicle a player is in, is always refused.** Absolute
   and not configurable. It's also what keeps a stolen cruiser safe: the model
   says "police", so layer 2 would wave it through.
2. **The model must be one this resource is configured to spawn**, built at boot
   from `Config.vehiclesByRegion` and the heli/plane tables. This is the layer
   doing the real work — a player's Sultan is not in the set — and it depends on
   nothing the client says.
3. **Entities are recorded against the player they were spawned for.**
   Helicopters and planes are created server-side so ownership is recorded
   directly; ground units are created client-side, so the server issues a
   single-use ticket with each authorisation and accepts one registration
   quoting it back.

Plus per-event rate limits, which these events had none of.

`Config.Security.strictOwnership` ships **off**: with layers 1 and 2 in place the
worst an unowned entity permits is one player interfering with another's units,
and turning it on before you've confirmed registration works converts every gap
into a police car that never despawns. Run `fenixguard` in the server console
during a pursuit — once it shows entities being owned, turn it on.

### The police only know what they can see

The chase loop re-tasked every driver to the player's live coordinates once a
second, so officers were omniscient: you could be in a garage, behind a hill or
three streets away in an alley and every unit still drove straight at you.
`Config.evasionTimes` decided when the *stars* came off, but nothing decided what
the units knew, so hiding was a countdown you sat through rather than a thing you
did.

`client/pursuit.lua` adds the missing state machine — **contact**, **searching**,
**re-acquired** — built from line of sight, a facing cone, and a grace period so
a pursuit doesn't drop you behind the first parked bus. Lose them and units drive
to your *last known position*, then sweep outward from it with a radius that
widens the longer you stay hidden. Firing a weapon inside earshot hands your
position straight back.

Everything the player reads a pursuit through hangs off that one state, because
all of it is really the same question:

- **AI blips**, with the view cone that *is* what each officer can see. One per
  vehicle, so a four-unit response doesn't smear the minimap.
- **Sirens** go quiet on a search — lights stay on. A unit that has lost the
  suspect wants to hear the street, not announce itself to it.
- **Radio traffic** describing your vehicle, its colour, the street and your
  direction of travel, built from real game data. Four or five calls per pursuit,
  not a running commentary. Route it into your own scanner UI with
  `Config.Pursuit.dispatchHandler`.
- **Passengers hold fire** at a suspect nobody can see, instead of shooting
  through walls at your live position.

### Roadblocks and spike strips

Dispatch service 8 is force-disabled in this resource and nothing replaced it, so
the entire response at every wanted level was "more cars behind you" — a pursuit
with no way to get in front of the suspect has only one shape.

`client/tactics.lua` places both ahead of you along your actual route, never in
your view, using the lane counts and carriageway width `client/roads.lua` already
computes: a block that spans a road has to know where the road ends, and a strip
laid across the wrong side of a dual carriageway is scenery. Only deployed
against a suspect the police can currently see — getting a unit in front of you
means knowing where you are going.

### Every officer drives differently

`SetDriverAbility(1.0)` and `SetDriverAggressiveness(1.0)` were re-applied to
every driver every cycle, so every unit in every pursuit drove identically: all
ramming, all cornering the same, none of them ever making a mistake. Profiles are
now rolled per officer and kept for their lifetime, scaled by wanted level the
way `Config.Combat` already scales shooting. Commanded speed is capped to what
the car can actually do — a riot van and an interceptor were both told 42 m/s.

Officers who end up on foot beside their car now **walk back and get in** rather
than teleporting into the seat in front of you, with the warp kept only as a
last resort for genuinely stuck peds.

### Officer budget

`maxScenes` alone is a poor cap: two four-officer foot posts is eight officers
in two scenes. Adds `maxNearbyCops` (6) within 260 m, costing one integer per
scene and no world scans.

### Hand-placed points are used verbatim

Three separate mechanisms were relocating authored points before anything
spawned — road snapping (up to 120 m), a shoulder offset with a 180° heading
flip, and `GetSafeCoordForPed` (up to 25 m). Points authored through `em_toolkit`
now carry an `exact` flag and skip all three.

### Notable fixes

- **`Config.PoliceWantedProtection` never worked.** Two upstream defects stacked:
  `isPlayerPoliceOfficer` was declared as a file-scope local ~2250 lines below
  its use, so the guards resolved a nil *global*; and both guards omitted call
  parens, so a function reference was always truthy. The first masked the second,
  meaning wanted levels applied to everyone including on-duty officers.
- **Traffic stops never ended.** `spawnStop` set no expiry at all, so a stop was
  permanent — an officer stood with a clipboard until you walked away. Now has a
  full wind-down: dwell → officer walks back → sirens off → both cars drive away.
- **Enforcement aborted silently on every catch.** `string.format('%d', x)`
  raises on Lua 5.3+ for fractional `x`, and speed in mph always is. The throw
  landed *after* the cooldown was set and *before* the wanted level was applied,
  so every catch detected the speeder, marked itself as done, and died.

Full detail in [`FORK-CHANGELOG.md`](FORK-CHANGELOG.md); the earlier patch series
this builds on is in [`UPSTATE_PATCHES.md`](UPSTATE_PATCHES.md).

---

## Project status

Honest assessment, because it affects what you should expect:

- The **upstream base is stable** and has been played extensively.
- The ambient layer's core — placement, radar detection, player pursuit — has
  been run and tuned.
- The **stop wind-down, NPC yield sequence, all-officer enforcement and ambient
  carjackings are statically verified but were never observed running.** Timings
  are first guesses: the carjack approach window (25 s), NPC yield delay (15 s)
  and stop dwell (60 s) will all want tuning against real play.

If ambient feels too sparse, loosen in this order: `radarFallbackToRoadNodes` →
`minSceneSpacing` → `maxNearbyCops`.

Known limits: NPC detection is position-only rather than path-swept (academic
below ~80 mph); "any cop" means any officer *this* system spawned, not police
peds from other resources.

---

## Features

Inherited from upstream, all configurable:

- Optionally enable AI police **only when player police are offline**, with a
  configurable threshold and an on-duty requirement.
- **Custom loadouts per unit**, randomised with spawn-chance weighting.
- **Custom units per jurisdiction** — Los Santos, Paleto Bay, Sandy Shores,
  Countryside — each with spawn weighting and a minimum wanted level. Riot and
  FBI units are weighted to appear at high wanted levels while regular units can
  still respond.
- Customisable **ped models** per unit.
- **Helicopters** at higher wanted levels (4 stars by default rather than 3), and
  military helicopters and planes if the player is airborne.
- Separate unit counts, despawn timers and spawn distances for **ground, air and
  helicopter** units.
- Customisable **evasion times** per wanted level.
- **Per-player police.** Two wanted players in one car draws double the response;
  four draws quadruple.
- Units are **spawned server-side** and their network IDs handed to the
  requesting client, so they sync properly across clients and you will see police
  chasing other players.
- **Stolen police vehicles** won't despawn while a player occupies them, so one
  taken mid-chase stays yours.
- **Player police protection** — officers can be exempted from wanted levels,
  optionally only while on duty. *(Fixed in this fork; see above.)*

**Known issue (upstream):** a police vehicle stolen by a player never despawns if
occupied at the moment the script would normally remove it.

---

## Requirements

**QBCore** (or QBX), used for notifications, counting online police, nearby
vehicle checks, dying/last-stand detection, and charging traffic fines. In
principle it could be removed by swapping the vehicle check to the native,
dropping notifications and last-stand logic, and setting
`Config.TicketSystem.fine.enabled = false`.

No vehicle add-ons are required — ambient units ship as base-game models, and
[weighted selection](#weighted-vehicle-selection) skips anything a client can't
spawn if you point it at your own liveries.

---

## Installation

### 1. Edit `qb-smallresources/client/ignore.lua`

`qb-smallresources` disables the police services this mod needs to control
directly.

**a)** Comment out the block from `SetAudioFlag` down to the last
`RemoveVehiclesFromGeneratorsInArea`:

```lua
CreateThread(function() -- all these should only need to be called once
    if Config.Disable.ambience then
        StartAudioScene('CHARACTER_CHANGE_IN_SKY_SCENE')
        SetAudioFlag('DisableFlightMusic', true)
    end
    -- SetAudioFlag('PoliceScannerDisabled', true)
    -- SetGarbageTrucks(false)
    -- SetCreateRandomCops(false)
    -- SetCreateRandomCopsNotOnScenarios(false)
    -- SetCreateRandomCopsOnScenarios(false)
    -- DistantCopCarSirens(false)
    -- RemoveVehiclesFromGeneratorsInArea(335.2616 - 300.0, -1432.455 - 300.0, 46.51 - 300.0, 335.2616 + 300.0, -1432.455 + 300.0, 46.51 + 300.0) -- central los santos medical center
    -- RemoveVehiclesFromGeneratorsInArea(441.8465 - 500.0, -987.99 - 500.0, 30.68 - 500.0, 441.8465 + 500.0, -987.99 + 500.0, 30.68 + 500.0)     -- police station mission row
    -- RemoveVehiclesFromGeneratorsInArea(316.79 - 300.0, -592.36 - 300.0, 43.28 - 300.0, 316.79 + 300.0, -592.36 + 300.0, 43.28 + 300.0)         -- pillbox
    -- RemoveVehiclesFromGeneratorsInArea(-2150.44 - 500.0, 3075.99 - 500.0, 32.8 - 500.0, -2150.44 + 500.0, -3075.99 + 500.0, 32.8 + 500.0)      -- military
    -- RemoveVehiclesFromGeneratorsInArea(-1108.35 - 300.0, 4920.64 - 300.0, 217.2 - 300.0, -1108.35 + 300.0, 4920.64 + 300.0, 217.2 + 300.0)     -- nudist
    -- RemoveVehiclesFromGeneratorsInArea(-458.24 - 300.0, 6019.81 - 300.0, 31.34 - 300.0, -458.24 + 300.0, 6019.81 + 300.0, 31.34 + 300.0)       -- police station paleto
    -- RemoveVehiclesFromGeneratorsInArea(1854.82 - 300.0, 3679.4 - 300.0, 33.82 - 300.0, 1854.82 + 300.0, 3679.4 + 300.0, 33.82 + 300.0)         -- police station sandy
    -- RemoveVehiclesFromGeneratorsInArea(-724.46 - 300.0, -1444.03 - 300.0, 5.0 - 300.0, -724.46 + 300.0, -1444.03 + 300.0, 5.0 + 300.0)         -- REMOVE CHOPPERS WOW
end)
```

**b)** Comment out this entire function — this mod handles it instead:

```lua
-- CreateThread(function()
    -- for i = 1, 15 do
        -- local toggle = Config.AIResponse.dispatchServices[i]
        -- EnableDispatchService(i, toggle)
    -- end

    -- local wantedLevel = Config.AIResponse.wantedLevels and 5 or 0
    -- SetMaxWantedLevel(wantedLevel)
-- end)
```

### 2. Edit `qb-smallresources/config.lua`

**a)** `hudComponents` contains `1` by default, which hides the wanted stars.
Remove it — note the example below has no `1`:

```lua
Config.Disable = {
    hudComponents = { 2, 7, 9, 19, 20, 21, 22 }, -- Hud Components: https://docs.fivem.net/natives/?_0x6806C51AD12B83B8
    controls = { 37 },                                            -- Controls: https://docs.fivem.net/docs/game-references/controls/
    displayAmmo = true,                                           -- false disables ammo display
    ambience = true,                                             -- disables distance sirens, distance car alarms, flight music, etc
    idleCamera = true,                                            -- disables the idle cinematic camera
    vestDrawable = true,                                         -- disables the vest equipped when using heavy armor
    pistolWhipping = true,                                        -- disables pistol whipping
    driveby = false,                                              -- disables driveby
}
```

**b)** Set the blacklisted police peds to `false` so they can spawn:

```lua
Config.BlacklistedPeds = {
    [`s_m_y_ranger_01`] = false,
    [`s_m_y_sheriff_01`] = false,
    [`s_m_y_cop_01`] = false,
    [`s_f_y_sheriff_01`] = false,
    [`s_f_y_cop_01`] = false,
    [`s_m_y_hwaycop_01`] = false,
}
```

### 3. Review `config.lua`

Read the comments and change what you want. Ambient settings live under
`Config.Ambient`; the new keys are documented in
[`FORK-CHANGELOG.md`](FORK-CHANGELOG.md#config-reference--new-keys).

### 4. Optional — `config.local/` for server-specific settings

`config.lua` ships portable: base-game vehicle models, stock job names, nothing
that assumes anything about your server. That is what makes it safe to pull an
update over, and also the wrong place to put your own add-on liveries — the next
update overwrites them.

Anything in a `config.local/` directory is loaded **after** `config.lua` and
`data/ambient_points.lua`, so it overrides both, and the directory is gitignored
so updates never touch it:

```lua
-- config.local/vehicles.lua
Config.Ambient.vehicles = {
    losSantos   = { ['yourcity_suv'] = 6, ['yourhwp_charger'] = 2 },
    sandyShores = { ['yoursheriff_suv'] = 6, ['yourhwp_charger'] = 2 },
}
```

Assign to the leaf you're changing, not the whole table — `Config.Ambient = {}`
would drop every other ambient setting with it. Split across as many files as
you like; they load in filename order. See
[`config.local.example.lua`](config.local.example.lua) for the full pattern.

The directory is absent from a clean checkout, and a glob that matches nothing
is a no-op, so this costs nothing if you never use it.

### 5. Add to `server.cfg`

```cfg
ensure fenix-police
```

---

## Exports

```lua
-- ADDS the value to the existing wanted level
exports['fenix-police']:ApplyWantedLevel(level)   -- 1 to 5

-- SETS the wanted level, if the new value is higher than the current one
exports['fenix-police']:SetWantedLevel(level)     -- 1 to 5

-- Added by this fork: is this player an on-duty police officer?
exports['fenix-police']:IsPlayerPoliceOfficer()

-- Added by this fork: is this player mid-roadside-stop? True from the moment a
-- stop is signalled until the citation is done and the wanted level clears.
-- Client-side. Useful for anything that should hold off during one.
exports['fenix-police']:IsPlayerAtTrafficStop()
```

### Dynamic wanted levels by location

Upstream supports assigning different wanted levels based on *where* a crime
happens, by triggering an event from your robbery scripts. Thanks to
**Tunsworthy** for this addition.

Add the trigger to `police:server:policeAlert` in
`[qb]/qb-policejob/server/main.lua`, and to
`qb-storerobbery:server:callCops` in `[qb]/qb-storerobbery/server/main.lua`.
Locations are defined in `config.lua`.

```lua
RegisterNetEvent('police:server:policeAlert', function(text)
    local src = source
    local ped = GetPlayerPed(src)
    local coords = GetEntityCoords(ped)
    local players = QBCore.Functions.GetQBPlayers()
    local alertData = { title = Lang:t('info.new_call'), coords = { x = coords.x, y = coords.y, z = coords.z }, description = text }
    for _, v in pairs(players) do
        if v and v.PlayerData.job.type == 'leo' and v.PlayerData.job.onduty then
            TriggerClientEvent('qb-phone:client:addPoliceAlert', v.PlayerData.source, alertData)
            TriggerClientEvent('police:client:policeAlert', v.PlayerData.source, coords, text)
        end
    end
    TriggerEvent('fenix:server:trigger', source, alertData)
end)
```

If you would rather not hand-edit those scripts, the bundled bridge below does
the same job by listening instead.

---

## Bundled — um_fenix_bridge

This fork ships an optional companion resource in
[`um_fenix_bridge/`](um_fenix_bridge/).

Most robbery scripts alert *player* police and stop there, so on a server with
nobody on duty a bank job draws no response. The bridge listens for alerts those
scripts already fire — `loaf_storerobbery`, `loaf_bankrobbery`, `qbx_jewelery`,
`ps-dispatch`, and the `police:server:policeAlert` catch-all — and applies a
configurable wanted level per crime type. This resource then dispatches units off
the back of that, so neither script needs to know about the other, and nothing
needs patching.

**It is not loaded automatically.** FiveM stops descending once a directory is
identified as a resource, so a nested resource is never discovered. The folder is
inert until you copy it out next to `fenix-police` and `ensure` it.

It has no hard dependencies and calls no `exports` on other resources — every
integration is a plain event listener, so anything you don't run simply never
fires. See [`um_fenix_bridge/README.md`](um_fenix_bridge/README.md).

---

## Optional — posted speed limits

Radar enforcement works out of the box using a flat unposted limit
(`unpostedLimitMph`, 80). To enforce **real posted limits per street**, add two
exports to the [`speedlimits`](https://github.com/Sinatra-/speedlimits) resource
so the limits stay defined there rather than being copied and drifting:

```lua
--- @param street string street name, as GetStreetNameFromHashKey returns it
--- @return number|nil mph
local function limitForStreet(street)
    if type(street) ~= 'string' then return nil end
    return Config.SpeedLimits[street]
end

exports('getSpeedLimitForStreet', limitForStreet)

--- @return number|nil mph, string|nil street
exports('getSpeedLimitAtCoords', function(x, y, z)
    local street = GetStreetNameFromHashKey(GetStreetNameAtCoord(x + 0.0, y + 0.0, z + 0.0))
    return limitForStreet(street), street
end)
```

The call is guarded by a resource-state check and a `pcall`, so if `speedlimits`
isn't running — or these exports aren't added — enforcement falls back to the
unposted limit rather than erroring.

Precedence when judging a driver:

1. A trap's authored "enforced speed" from `em_toolkit`
2. Posted limit + `toleranceMph` (15)
3. `unpostedLimitMph` (80) where the street has no sign defined

---

## Commands

| Command | Purpose |
|---|---|
| `/ambientpolice [on\|off]` | Toggle ambient policing, and list live scenes with distances, arm state, and the speed limit applying where you stand. **The bare form toggles** — pass `on` or `off` explicitly to be sure. |
| `/ambientpolicereload` | Re-read `em_toolkit` points and clear existing scenes |
| `/radartrace` | Per-second trace of the enforcement decision: tick state, speed vs allowed, and per-scene distance / reach / visibility |
| `/fenixroads` | Draw every no-go zone in `Config.Roads.exclusionZones` as a wireframe box. **The zones are hand-measured — check them this way before trusting them.** |
| `/fenixroads here` | Report what the road system makes of the ground you are standing on: zone, street name, whether it is excluded, whether a unit could spawn there, and the lane count in each direction |
| `/fenixtactics` | List live roadblocks and spike strips with distances and entity counts |

---

## Credits

- **[Fenix](https://github.com/FenixPK)** — created the original resource, so he
  could play FiveM QB-Core with his wife Rainbowicus. Everything here is built on
  that work.
- **Tunsworthy** — the location-based dynamic wanted level system.
- **Sinatra** — the `speedlimits` resource (MIT, © 2022), which the optional
  posted-limit integration reads from.
- **Upstate Mafia** — this fork's ambient enforcement layer and `um_fenix_bridge`.

Fenix created this because streaming `dispatch.meta` and `dispatchtuning.ymt`
isn't supported by FiveM, leaving no way to have AI police while controlling how
they spawn and behave.

### Support the original author

If you find this useful, consider supporting Fenix:

[![Donate](https://www.paypalobjects.com/en_US/i/btn/btn_donateCC_LG.gif)](https://www.paypal.com/donate/?hosted_button_id=8UEUW7KYFSF48)

---

## Licence

**GPL-3.0**, inherited from [FenixPK/fenix-police](https://github.com/FenixPK/fenix-police).
See [`LICENSE`](LICENSE).

Changes made downstream of upstream are recorded in
[`FORK-CHANGELOG.md`](FORK-CHANGELOG.md) and [`UPSTATE_PATCHES.md`](UPSTATE_PATCHES.md),
which together serve as the GPL-3 §5(a) statement of changes.

The `um_fenix_bridge` companion is licensed GPL-3.0 to match.

---

## More images

<img src="img/FenixPolice002.jpg" alt="Fenix Police Response" width="800"/>

<img src="img/FenixPolice003.jpg" alt="Fenix Police Response" width="800"/>

<img src="img/FenixPolice004.jpg" alt="Fenix Police Response" width="800"/>
