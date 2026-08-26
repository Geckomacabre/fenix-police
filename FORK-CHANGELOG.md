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

## 2.4.0 — ambient density tuned down, convoy scene added — 2026-08-24

`client/ambient.lua` (new `spawnConvoy`), `Config.Ambient` in `config.lua`.

Reported: a cop on 7 out of 10 corners, and — separately, and liked — two or
three cruisers occasionally seen driving together with no lights on. Asked for
the first turned down and the second turned into a real thing.

### Tuned — ambient encounter rate

Four settings govern how often you run into something, not what kind:

| Setting | Was | Now |
|---|---|---|
| `spawnInterval` | 8s | 15s |
| `maxScenes` | 4 | 3 |
| `maxNearbyCops` | 6 | 4 |
| `minSceneSpacing` | 90m | 120m |

At 8 seconds with a cap of 4, the scene population barely had time to fall
before the next attempt topped it back up — closer to "every open slot always
full" than to background presence. `spawnInterval` is the biggest lever on
that; `maxScenes` and `maxNearbyCops` cap how much is visible at once,
`minSceneSpacing` stops independent scenes landing close enough to read as one
big encounter.

Scene-kind weights are unaffected by any of this — weights decide *which* scene
spawns when one does, not how often one does. Turned down here on purpose,
because the frequency complaint and the kind mix are different questions and
tuning the wrong one doesn't fix the right one.

### Added — the `convoy` scene

Two or three cruisers travelling the same road together, lights and sirens
off. This was already happening by accident: independent `patrol` scenes,
spawned close enough together and started on the same road, drift into a loose
group on their own, because `TaskVehicleDriveWander` just keeps a car on
whatever road it is already on. It looked good and cost three times what it
should have to get — three scene slots and three officers out of the
nearby-cops budget for one visual, which is also part of why corners felt
crowded.

`spawnConvoy` is the same look, deliberately, for the price of one scene.
Placement reuses `bestRoadNode` for the lead car exactly as `patrol` does;
trailing cars are placed nose-to-tail behind it along the road's own heading
(`Config.Ambient.convoySpacing`, 9m), each checked for clearance individually
so a trailing spot landing on parked traffic just spawns one fewer car rather
than failing the whole scene. One vehicle model for the group — matching cars
is most of what sells "travelling together" over "three coincidental patrols."

Two cars by default, three `convoyThirdCarChance` (35%) of the time. Its own
cooldown (`convoyCooldownSeconds`, 240s) for the same reason `stop` and
`pursuit` have one: a group is more noticeable than a single patrol car, so the
weight alone can't express "occasional" — it needs a floor. Added to
`Config.Ambient.weights` at 2, with `patrol` trimmed 4 → 3 alongside it so the
total rate of "driving cop" encounters doesn't rise just because there are now
two kinds of it.

Enforcement (radar-style speed checks against the player) applies to convoy
scenes exactly as it already does to patrol — that's `enforceFromAllCops`,
unrelated to and untouched by this change. A convoy that happens to be nearby
when you fly past still notices, which is correct: they're cops, not props.

---

## 2.3.1 — two cruisers spawning on one point — 2026-08-24

`client/roads.lua`, `client/client.lua`, `config.lua`.

### Fixed — two cruisers landing on the same point and flipping each other

Reported: two cop cars spawning on top of each other and flipping, three times
in one session, always in front of the player.

Two independent bugs, both introduced in 2.1.0's road rewrite.

**No coordination between concurrent spawn requests.** `maintainPoliceUnits` can
fire several spawn requests in one tick, and each is a round trip to the server
before any vehicle exists. `IsPositionOccupied` cannot see a car that has not
been created yet, so nothing stopped two requests picking the same spot. This
used to happen rarely, because the old first-fit node search took whichever
random candidate passed first and scattered. The 2.1.0 rewrite scores every
candidate and keeps the best, and two calls a few milliseconds apart — same
player position, same road network — reliably converge on the *same* best
lane centre, with the same deterministic 'outer' lane choice putting them on the
exact same point.

Fixed with a short-lived reservation: the winning point is claimed for
`Config.Roads.reservationSeconds` (25s), and a later candidate within
`spawnSeparation` (18m) of a live reservation is rejected. The reservation only
has to outlive the round trip — once the vehicle exists, the ordinary occupancy
check takes over. Cleared when a pursuit ends, so the next one doesn't work
around spots promised to units that no longer exist.

**Units spawning in front of the player.** Two problems compounding into one
symptom.

The rear-arc bias was built by converting the player's forward vector to a
heading with `GetHeadingFromVector_2d`, adding the arc offset, and feeding the
result to `sin`/`cos`. GTA headings increase anticlockwise from north; the
`sin`/`cos` pairing used throughout this codebase (see `forwardOf` /
`rightOf` in `client/roads.lua`) sweeps the opposite way. The two conventions
run in opposite directions, so the result was the player's facing **mirrored
across the north-south axis**. Facing exactly north or south, the mirror is
its own inverse and the bug is invisible — which is almost certainly why it
shipped unnoticed. Facing anywhere else, "behind" resolved to a direction with
no fixed relationship to actually-behind, up to and including dead ahead.
Fixed by rotating the forward vector directly, which has no heading-convention
round trip to get backwards.

Separately: the *old*, pre-2.1.0 code rejected any candidate whose position
dotted positive against the player's forward vector — a hard "never in front"
rule. The 2.1.0 rewrite kept the rear-arc *sampling* bias but dropped that
rejection, replacing it with a scoring bonus on which way the ROAD's own
direction faced the target. Those are different questions: sampling biases
where you start looking, but the sample point is only a seed — `roadAt`
resolves it to the nearest real road, which can be a considerable distance
away in any direction, rear sample included. Nothing was left refusing a
final position ahead of the player. Restored as `Config.Roads.maxForwardDot`
(0.0 — the whole forward half-plane is refused), checked against the final
lane position rather than the sample point.

With both fixed independently, either bug reproduces the report on its own —
the mirroring explains appearing in front regardless of facing, and the missing
reservation explains two cars doing it in the same place. Together they were
worse: the mirrored sampling made "in front" the common case rather than the
occasional one, so a same-tick pair of requests converging on one best road was
also usually converging on a road ahead of the player, which is where the
flipping was being watched happen.

`getSafeSpawnPoint`'s widen-the-band retry (for a player on a long rural road
past `maxPoliceSpawnDistance`) now has a third pass if the first two still find
nothing: same widened band, `maxForwardDot = 0.7` (a 90-degree forward cone
allowed rather than none). Strictly-behind is correct almost always, but parked
facing the end of a cul-de-sac there may be no road behind at all, and a unit
that never arrives is worse than one seen coming. The cone stays excluded even
here, so this can place a unit alongside or diagonally ahead, never straight
into the windscreen.

`Config.Roads.clearance` raised 3.0 -> 4.0. A police cruiser is roughly 5m long;
3m left cars that spawned close but not reserved-close still overlapping.

## 2.3.0 — server-side entity security — 2026-08-24

New file `server/guard.lua`; `Config.Security` in `config.lua`;
`server/server.lua` (every mutating net event), `client/client.lua`
(ground-unit registration), `fxmanifest.lua`.

### Fixed — the server acted on any network ID any client sent it

Four handlers resolved a network ID straight off the wire and operated on
whatever came back, with no validation of any kind:

| Handler | What a client could do |
|---|---|
| `deleteSpawnedEntity` | Delete **any networked entity on the server** |
| `deleteSpawnedPed` | Delete any networked ped |
| `fenix-police:rearmOfficer` | Give a weapon to any ped, **including a player's** |
| `fenix-police:unlockOfficerVehicle` | Unlock any vehicle's doors |

`deleteSpawnedVehicle` checked for a player *occupant*, which protected an
occupied car and not a parked one.

Network IDs are small sequential integers. None of this needed guessing, only
counting. On a QBCore server "unlock any vehicle" and "delete any vehicle" are
theft and griefing primitives and "arm any ped" is free weapons for anyone who
can send an event.

**Root cause.** `activeGroundUnits` in `server.lua` is the registry these could
have been validated against, and it is only ever assigned `nil` — there is no
write that puts anything in it. It is a leftover from the server-side ground
spawn path that the client-side delegation replaced, so the server held no record
of what this resource had created. (The same emptiness is why
`applyGroundPursuitTask` can never fire: it loops over a permanently empty
table. Left alone here — see the note at the end.)

### The three layers

**1. Player entities are untouchable.** A player's ped, or a vehicle a player is
sitting in, is refused before anything else is considered. Not configurable. This
is also what makes layer 2 safe on a *stolen* cruiser: the model says "police",
so the allowlist would wave it through, and this is what stops the car being
deleted out from under whoever took it.

**2. Model allowlist.** The entity's model must be one this resource is
configured to spawn, built at boot from `Config.vehiclesByRegion`,
`Config.polHelis`, `Config.milHelis` and `Config.milPlanes`. A server owner who
adds an add-on cruiser to those tables gets it allowlisted automatically and
never has to know `guard.lua` exists.

This is the layer that closes the serious hole, and the important property is
that it depends on **nothing the client asserts**. A player's Sultan and a
player's freemode ped are not in the set, and no amount of lying about network
IDs puts them there.

**3. Ownership.** Entities are recorded against the player they were spawned for.
Helicopters and planes are created server-side, so ownership is recorded directly
at the point of creation. Ground units are created client-side, so there is
nothing to record at creation — instead the server issues a **single-use ticket**
when it authorises a spawn, and accepts one registration quoting that ticket
back. A client can only ever register entities the server just told it to make,
and every reported ID is re-checked against the allowlist rather than trusted.

`Config.Security.strictOwnership` ships **off**, deliberately. With layers 1 and
2 in place, the worst an unowned entity permits is one player interfering with
another player's police units — griefing, not theft. Turning it on before
confirming registration works on a given server converts every gap into a police
car that never gets cleaned up, because the client drops the unit from its own
tracking whether or not the server honoured the delete. Run `fenixguard` in the
server console during a pursuit; once it shows entities being owned, turn it on.

### Added — rate limiting

The spawn events had no limit at all: a client could sit in a loop asking for
units. Limits are per player, per event group, per minute.

The ceilings are deliberately generous, because these events are not called at
remotely similar rates. `spawn` is a deliberate request made a handful of times a
minute. `unlock` and `rearm` fire from the chase loop once per officer per cycle.
`delete` arrives in **bursts of thirty** when a pursuit ends and the five-pass
cleanup sweep runs over ten units and their crews — a single flat 90/minute would
have refused legitimate deletes and left police cars in the world permanently.
Too tight is worse than absent here.

### Fixed — the crime-alert event was a wanted-level cannon

`fenix:server:trigger` applies a wanted level to every player within 10m of a
reported crime, and took the crime's coordinates **from the client**. Any client
could therefore name coordinates anywhere on the map and star whoever was
standing there, repeatedly.

The fix is to stop trusting the location rather than to stop trusting the caller:
a player reporting a crime is reporting one they are *at*, so coordinates further
than `Config.Security.maxAlertDistance` (100m) from the caller are refused. Calls
that did not come from a player — another resource triggering this server-side,
where `source` is 0 — skip the check, because there is no caller to measure
against and a server-side caller is already trusted. The coordinate fields are
also type-checked now; they were passed straight into arithmetic.

Separately, the handler printed five lines to the server console **per call**,
unconditionally. That is a console flood on its own, and none of it is useful
outside debugging. Now behind `Config.isDebug`.

### Also

- `rearmOfficer` took `loadoutKey` and used it to index `Config.loadouts`
  directly. Now type-checked before the lookup, so a non-string falls through to
  the default rather than reaching the indexing.
- `deleteSpawnedVehicle`'s occupied-vehicle check moved into the shared gate, so
  it now applies to every handler rather than only that one. The client is told
  the same thing on any refusal as it was on the occupied case, because from its
  side the outcome is identical: this vehicle is not ours to remove.
- `playerDropped` releases that player's ownership records and outstanding
  tickets, so the tables cannot grow for the life of the server and a recycled
  server id cannot inherit somebody else's entities.
- `fenixguard`, console-only, reports allowlist size, entities owned per player,
  outstanding tickets and whether strict ownership is on.

### Note — two pre-existing gaps left alone

**The dead `activeGroundUnits` machinery.** `applyGroundPursuitTask` and the
1-second loop that calls it operate on a table nothing writes to. It should
either be wired up or removed, but it is a behaviour question rather than a
security one and removing it is not this change.

**`stolenVehicles` on the client is written and never read.** Vehicles the server
refuses to delete are recorded for later cleanup that does not exist. Harmless —
the table is bounded by the number of police vehicles in a session — but the
"delete later when abandoned" behaviour its comment describes was never
implemented.

---

## 2.2.0 — pursuit perception, roadblocks & driving profiles — 2026-08-24

New files `client/pursuit.lua` and `client/tactics.lua`; `Config.Pursuit`,
`Config.Driving` and `Config.Tactics` in `config.lua`; `client/client.lua`
(chase loop, master loop), `fxmanifest.lua`.

### Fixed — officers knew exactly where you were at all times

`handleChaseBehavior` re-tasked every driver to `playerCoords` — the player's
live position — once a second. Units were therefore omniscient. You could be
inside a garage, behind a hill, or three streets away in an alley and every car
still drove straight at you. `Config.evasionTimes` governed when the STARS came
off; nothing governed what the units knew, so hiding was a countdown you sat
through rather than a thing you did.

`client/pursuit.lua` adds the missing model — **contact / searching /
re-acquired** — and `targetCoords()` is the whole point of it in one function:
the player's real position while somebody can see them, the last place they were
seen once nobody can.

Perception is distance, then a facing cone, then a ray, cheapest first. Air crews
skip the cone deliberately: a helicopter carries a spotter whose entire job is
looking down, and a forward arc makes them useless at the one thing they exist
for. This is also most of what now justifies calling one in — a heli overhead is
what stops you breaking contact by turning a corner.

Two details that matter more than they look:

- **A grace period before contact is lost.** Line of sight breaks constantly in
  city driving — every corner, every truck, every overpass. Without
  `loseContactMs` the pursuit would drop you at the first parked bus.
- **Gunfire reveals.** Firing inside `gunfireRange` of any unit hands your
  position back regardless of cover, so shooting your way out of a hiding place
  does not work.

Search behaviour: drive to the last known position, then sweep outward from it,
with the radius growing the longer contact stays lost — tight on the sighting,
loosening into the surrounding blocks. `TaskVehicleChase` is not used during a
search, because it tracks the player *entity*, which is precisely the omniscience
being removed.

The module reports `hasContact() == true` when disabled. Every caller depends on
that: with perception off the intended behaviour is the old omniscient pursuit,
not one where nobody can ever see you.

### Added — AI blips with view cones

Nothing in the resource gave a spawned officer or vehicle a blip. During a
pursuit the minimap was empty, which reads as a broken script more than anything
else the response does.

Officers now carry GTA's own AI blips, and the cone is not decoration: it draws
`sightRange` and `sightFov`, the same numbers the contact model runs on. A player
watching the cones sweep during a search is reading the actual state.

One blip per vehicle by default (`blipDriversOnly`) — a four-unit response is
eight officers, and eight overlapping blips on four cars is a smear that hides
the cones underneath it. Officers on foot always blip; at that point they are the
unit. Re-evaluated every contact tick rather than once at spawn, so a passenger
who bails becomes a blip and a driver who is dragged out stops being one.

### Added — radio traffic

`SetAudioFlag('PoliceScannerDisabled', ...)` was toggled and nothing ever played.

Dispatch now calls in the opening description, the loss of visual and the
re-acquisition, built from real game data: vehicle make from the model label,
colour from the paint index, street from `GetStreetNameAtCoord`, direction as an
eight-point compass bearing. Rate limited to four or five calls per pursuit
rather than a running commentary. `Config.Pursuit.dispatchHandler` routes the
finished string into a scanner UI, phone app or `ox_lib` instead of QBCore
notifications.

Officers also call out spotting and losing the target. **Ambient speech is used
rather than scanner audio deliberately**: a speech context this build of the game
does not have simply doesn't play, where a bad `PLAY_POLICE_REPORT` name is an
error. Nothing in that path is load-bearing.

### Added — roadblocks and spike strips

`Config.Tactics`, `client/tactics.lua`. Dispatch service 8 (DT_PoliceRoadBlock)
is force-disabled in `client.lua` and nothing replaced it, so the entire response
at every wanted level was "more cars behind you". A pursuit with no way to get in
front of the suspect has only one shape.

Both reuse what 2.1.0 already computes. A roadblock parks one car broadside per
blocked lane, which requires knowing how many lanes run the player's way and
where the carriageway ends; a strip laid across the wrong side of a dual
carriageway is scenery. Lane numbering is the same as `client/roads.lua` uses to
place a car: direction A occupies the rightmost `fwdLanes` slots.

Placement rules for both: ahead along the actual direction of travel, sampled
far-to-near so they land at the far end of the band where possible (the
difference between an obstacle and an ambush), never inside the player's view
when created, never inside a `Config.Roads` exclusion zone, and only against a
suspect the police can currently see — which is also what stops a search becoming
a wall of roadblocks in every direction at once.

Spike hits are scripted, because the stinger prop has no collision that bursts
tyres; in the base game that effect is entirely mission script. Contact runs on a
50ms tick, since at 90mph a car crosses a strip's whole footprint inside one
1000ms cycle.

Roadblock cars run lights without sirens. A stationary wailing siren two hundred
metres ahead is the tell that ruins the surprise.

### Fixed — every officer drove identically

`SetDriverAbility(officer, 1.0)` and `SetDriverAggressiveness(officer, 1.0)`, on
every driver, re-applied every cycle. Maximum skill and maximum aggression on
everyone meant every unit rammed, every unit cornered the same, and none of them
ever made a mistake.

`Config.Driving` rolls a profile per officer, once, kept for their lifetime — the
same shape as `Config.Combat.engageChance` — scaled by wanted level, so the
wanted level now shows up in the driving and not only in the shooting.

Commanded speed was a flat 42 m/s regardless of model; a riot van and an
interceptor got the same number, and the van spent the pursuit driving like it
was late for something. Now capped to a fraction of the car's own estimated top
speed, with a per-officer multiplier so a convoy doesn't move as one object.

### Fixed — officers teleported back into their car

`SetPedIntoVehicle` ran every cycle in the on-foot branch, so an officer who got
out — or was dragged out — snapped into the seat in front of you.

Now `TaskEnterVehicle`: turn, walk over, open the door. The warp is kept as a
last resort after `reboardPatience` cycles or beyond `reboardGiveUpDistance`,
because something genuinely does get officers stuck (ragdolled under the car,
wedged in scenery, holding a task that will not clear) and a pursuit unit
standing in the road forever is a worse outcome than one visible teleport.

The task marker below that branch used to be reset to `VehicleChase`
unconditionally, which would have wiped the `Reboarding` marker every cycle and
re-issued the enter task forever, leaving the officer walking on the spot. It is
now conditional.

### Fixed — passengers shot at suspects nobody could see

`TaskCombatPed` was issued on the hostility roll alone. Through a search that
means a passenger firing through walls at the player's live position, which gives
the hiding place away and reads as the aimbot it is. Now gated on contact.

### Note — one piece of dead config, not changed

`client.lua` hard-codes `EnableDispatchService(..., false)` for indices 1, 4, 6,
7, 8, 9 and 10 immediately after the loop that applies
`Config.AIResponse.dispatchServices`, so those seven config keys do nothing.
Every shipped value is `false`, so the behaviour is correct today and the only
symptom is that turning one on silently fails. Left alone rather than fixed
blind: reconciling it means deciding which of those services should be allowed
back now that roadblocks are handled here, and that is a tuning call.

---

## 2.1.0 — lane-correct placement & airside no-go zones — 2026-08-24

New file `client/roads.lua`; `Config.Roads` in `config.lua`;
`client/client.lua` (`getSafeSpawnPoint`), `client/ambient.lua`
(`bestRoadNode`, `spawnRadar`), `fxmanifest.lua`.

### Fixed — units spawning in the wrong lane, and facing the wrong way

Both spawners took whatever `GetClosestVehicleNodeWithHeading` returned and used
it verbatim. Two things are wrong with that, and they are the same mistake:

- **A vehicle node is the centre line of a road, not a lane.** Spawning on it
  drops a cruiser straddling the paint.
- **The heading a node reports is one of the road's two legal travel
  directions**, picked by the engine, not the one that suits the side of the
  road you are on. Roughly half of all spawns therefore faced oncoming traffic.

The node natives cannot fix this because they do not expose lane counts.
`GET_CLOSEST_ROAD` does: it returns the road segment's two endpoints plus the
number of lanes running in each direction along it. From those you can compute a
real lane centre and a direction the road actually permits, which is what
`client/roads.lua` now does for both the pursuit spawner and the ambient system.

Lane numbering runs 1..total from the left-hand edge looking along the segment's
own direction. Traffic in that direction occupies the rightmost `fwdLanes` slots
and traffic against it the leftmost `bwdLanes`, with the centre line in the
middle of the full set — which holds for an undivided street (1 + 1, centre line
is the paint) and for one carriageway of a divided highway (3 + 0, centre line is
the middle of those three) alike. One formula, both cases.

Facing the player is now **scored as a preference, never required**. Requiring it
is precisely how you end up spawning against the flow on a one-way street; a road
with no lanes in the direction you want simply doesn't offer that direction, and
the unit drives round instead.

### Added — `Config.Roads.exclusionZones`, and the airfields

Police drove around LSIA's runways, taxiways and aprons because those surfaces
carry vehicle nodes like any other road, and nothing distinguished them.

Two mechanisms, because one is not enough:

1. **Spawn rejection.** A candidate point inside a zone is discarded.
2. **`SET_ROADS_IN_AREA`.** The AI road network is switched off inside the zone,
   so the pathfinder stops seeing those nodes at all. This is the half that
   matters for the actual complaint: rejecting spawns keeps units from
   *appearing* airside, but a unit that spawned on Greenwich Parkway will still
   happily route across the airfield while the nodes are live. It applies to
   ambient traffic too, which is correct — airside has no civilian traffic.
   Re-applied on a timer, because the engine restores node state when a region
   streams back in, and handed back on resource stop.

Zones may be boxes, cylinders or polygons, each with a `zMin`/`zMax` band. The
band is not optional in practice: without a ceiling, a box over an airfield also
swallows any road bridging past it. LSIA and Fort Zancudo ship enabled; Sandy
Shores ships **disabled**, because the strip sits close enough to Route 68 that a
box large enough to cover it risks eating real road.

**The shipped boxes are hand-measured.** `/fenixroads` draws them in-world and
`/fenixroads here` reports what the system makes of the ground under your feet —
zone, street name, exclusion state, spawnability, and lane counts. Trim them in
`config.local/`.

### Added — street-name rejection

Backing up the zones everywhere they don't reach: a candidate on a surface the
game gives no street name to is rejected. GTA V names essentially every drivable
public road, rural trails included (`Cassidy Trail`, `Joshua Rd`), and names none
of the airside surfaces, car park aisles or dirt scrapes. It is the cheapest
reliable discriminator available and, unlike a coordinate box, it needs no
maintenance. `Config.Roads.requireNamedStreet`, on by default.

### Added — reachability test

`Config.Roads.maxTravelRatio` (4.0) rejects a point whose driving distance to the
player exceeds that multiple of the straight-line distance. This is what catches
placements that look perfect on a map and are useless in play: the freeway deck
directly above the player, the far bank of the Alamo Sea, the other side of a
canyon. 90 m apart, three kilometres by road, and the unit spends its entire
lifetime driving.

### Fixed — radar traps parked on the far verge, two shoulder-widths out

`spawnRadar` snapped an authored point to the road, offset it 4.5 m to the right
of the *road's* heading, then flipped the car 180°. The flip left it on the verge
belonging to the other direction of travel — the wrong side of the road for the
traffic it was supposedly watching. Placement now resolves against the direction
the car will face, so the verge and the facing agree.

Separately, the `radarFallbackToRoadNodes` path applied the shoulder offset
twice: once inside `bestRoadNode`, once again below it. On a wide road that put
the cruiser in the scenery.

### Changed — `Config.Ambient.shoulderOffset` superseded

Replaced by `Config.Roads.shoulderOffset`, measured from the **edge of the
carriageway** rather than from the centre line — the only way one number works on
both a two-lane street and a six-lane boulevard. Default 1.5 m: a car is about 2 m
wide, so that parks it mostly on the verge with a wheel still on the tarmac,
which is how a real speed trap sits. The old key is left in `config.lua` with a
note so an existing `config.local/` override is visible rather than silently
ignored.

`Config.Ambient.nodeSamples` raised 10 → 20. Candidates now have to clear lane
geometry, the no-go zones and the reachability test, so more of them are
rejected.

### Changed — "no spawn point found" is no longer an error

It was printed unconditionally as `ERROR`. There is genuinely nowhere legal to
put a car when the player is on a runway, out at sea or deep in the hills, and
skipping the dispatch is the whole point of the road checks. Now debug-gated, and
the next spawn tick tries again.

### Note — air units unchanged

`getRandomPointInRange` still uses independent X/Y offsets, so a "500 m" heli
spawn is up to ~707 m diagonally, and it does no zone checking. Left alone
deliberately: air spawns are 150 m+ above the player, well clear of every zone
ceiling, and changing the distance maths would shift heli behaviour that is
currently tuned.

---

## 2.0.1 — roadside citations & weighted vehicle picks — 2026-07-31

### Added — traffic citations as an alternative to arrest

`Config.TicketSystem`, `client/client.lua` (new section below the arrest
system), `server/server.lua`.

Being caught had exactly one ending: the BUSTED cinematic and a teleport to the
nearest station. That is the right outcome for a robbery and the wrong one for
the offence that most often triggers it — speeding past a radar trap halfway
through a run. The arrest doesn't cost you money, it costs you your position.

The surrender key (default `H`) now does one of two things depending on where
you are:

| Where | Outcome |
|---|---|
| On foot, wanted | Unchanged — hands up, cuffs, BUSTED, station |
| Driving, wanted ≤ `maxWantedLevel` | Hazards on, officer at your window, citation, drive away |

Sequence: signal → the pursuit stops re-tasking → nearest unit within
`approachDistance` claims the stop and halts → one officer out of the stopped car
→ walks to the driver's-window offset (the same one the ambient `stop` scenes
use) → `WORLD_HUMAN_CLIPBOARD` for `writeSeconds` → citation → everyone drives
off → wanted level clears `dispersalSeconds` later.

Design points worth keeping if this is ever merged forward:

- **One officer, from a stopped car.** Same contract as
  `handleSurrenderApproach`, for the same reason: the original arrest code
  emptied every responding unit at once and had to be disabled.
- **The claim latches.** Re-electing the closest unit each cycle would hand the
  stop to whichever car rolled a metre nearer, mid-walk. The claim is dropped
  only if that unit is culled out from under it.
- **Units beyond `approachDistance` are returned to the chase loop**, not held.
  Holding them meant units spawned to work the stop sat at their spawn point
  forever, because the chase loop is what actually drives them to you.
- **`ticketWrapUp` keeps the wanted level on** while everyone drives away. The
  cleanup watchdog deletes every spawned unit the instant you stop being wanted,
  so clearing it immediately blinked the car at your bumper out of existence.
  `maintainPoliceUnits` is suppressed during wrap-up for the same reason —
  spawning a replacement into a finished stop reads as a bug.
- **Controls are locked only while the citation is being written**, never while
  you're still driving to a stop. A disabled control never fires the command
  bound to it, so locking earlier would also kill the key that cancels.
- **The fine is priced and charged server-side.** The client sends the wanted
  level and nothing else, and the level is clamped to `maxWantedLevel` before it
  indexes `fine.amounts`. Insufficient funds is never an arrest.
- **The ambient trap stands down.** `catchPlayer` leaves its cruiser on a
  `TaskVehicleChase`, which circles and PITs a car that has already pulled over.
  `standDownForTrafficStop` in `client/ambient.lua` halts it once, via the new
  `IsPlayerAtTrafficStop` export.

New export: `exports['fenix-police']:IsPlayerAtTrafficStop()` (client).

### Added — `config.local/` for server-specific settings

`fxmanifest.lua`, `.gitignore`, `config.local.example.lua`.

`config.lua` is both the documentation and the defaults, which means every
server-specific edit to it — add-on vehicle models, job names, coordinates — is
lost or conflicts the next time this fork is updated. That is the direct reason
the pack liveries above were pulled back out of the shipped config: there was
nowhere else for them to go.

Now there is. `shared_scripts` loads `config.local/*.lua` last, after
`config.lua` and `data/ambient_points.lua`, so anything in that directory
overrides both. The directory is gitignored and absent from a clean checkout.

A **directory** rather than a named `config.local.lua` on purpose: a glob that
matches nothing is a no-op, whereas a literal missing filename in a script list
is an error at resource start. It also means `config.local.example.lua` can be
committed as documentation at the repo root without ever being loaded, because
it sits outside the directory the glob covers.

### Added — weighted vehicle selection for ambient units

`Config.Ambient.vehicles`, `Config.Ambient.vehicleFallback`,
`client/ambient.lua`.

Ambient units picked uniformly from a flat list per region, which can express
"these models" but not "mostly this agency, occasionally that one". They now go
through one function, `regionVehicle`, and `Config.Ambient.vehicles` accepts a
`model = weight` map as well as the original array (picked uniformly, unchanged
behaviour — `list[1] ~= nil` tells the shapes apart).

The defaults stay **base-game models only**. This is a config file that ships,
so server-specific add-on liveries do not belong in it; the weighting exists so
each server can point it at its own.

Two details make that safe:

- `pickWeighted` filters uninstalled models *inside* the roll rather than after
  it, so a region weighted mostly toward a pack a given client doesn't have
  still returns the models it does — no wasted picks, no failed spawns.
- `vehicleFallback` catches a region where nothing at all resolves, so a client
  missing every add-on still gets ambient police rather than empty scenes.

---

## 2.0.0 — ambient enforcement — 2026-07-31

First tagged release of this fork, on top of upstream 1.0.2. The major bump is
this fork's own numbering and says nothing about upstream's — it reflects that
ambient enforcement is a new layer rather than an increment.

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
