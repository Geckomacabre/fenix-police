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
vehicle checks, and dying/last-stand detection. In principle it could be removed
by swapping the vehicle check to the native and dropping notifications and
last-stand logic.

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

### 4. Add to `server.cfg`

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
