# fenix-police 3.0 — feature specs

These build on the fixed code (all audit fixes merged). Every feature:
- is config-gated with a documented block in config.lua and in-code defaults (a missing key = shipped default; `enabled = false` = old behaviour);
- never throws inside a long-running loop; never leaks entities/threads;
- respects the existing state flags: isSurrendering, isBeingArrested, isBeingTicketed/ticketWrapUp, aftermath.active, FenixMorale.isRetreating/isReleased, police-job protection (isPlayerPoliceOfficer);
- matches the house style (explanatory WHY comments in the existing voice, no tags, no mention of AI/agents);
- gets a `/fenix<thing>` debug command only if it has meaningful live state to inspect.

---------------------------------------------------------------------------
## F1. Less-lethal takedowns: taser, tackle, cuffs  (client/client.lua — foot chase)

Problem: the ONLY arrest trigger in the resource is voluntary surrender (handleSurrenderApproach → triggerArrest). A suspect who keeps running on foot is followed forever by a non-hostile chaser or shot by a hostile one. Nobody can actually be caught.

Design (inside handleFootChase, for the committed chaser, only when the chaser is NOT in 'FootCombat' and the player is on foot, alive, not already being arrested/ticketed/surrendering):

Config.FootChase.takedown = {
    enabled = true,
    taser = {
        enabled = true,
        maxWantedLevel = 3,          -- at or below this, a non-hostile chaser draws a taser instead of chasing forever
        weapon = 'WEAPON_STUNGUN',
        minRange = 3.0, maxRange = 12.0,
        cooldownMs = 6000,           -- per officer between shots (cartridge reload)
        firearmBlocks = true,        -- never tase a suspect holding a firearm (that's a gun call, Config.Combat decides)
    },
    tackle = {
        enabled = true,
        maxWantedLevel = 5,
        range = 1.8,                 -- chaser within this of a running suspect may tackle
        chance = 0.45,               -- per attempt
        cooldownMs = 3500,
        ragdollMs = 2500,
    },
    cuffRange = 3.0,                 -- an officer this close to a downed suspect starts the arrest
    getUpGraceMs = 4000,             -- wait at most this long for the ragdoll to end before cuffing
}

- Taser: LOS (HasEntityClearLosToEntity(chaser, playerPed, 17)), range window, cooldown, suspect not holding a firearm (IsPedArmed(playerPed, 4) false — flag 4 = firearms) when firearmBlocks. GiveWeaponToPed(stungun, 1, false, true) once; SetCurrentPedWeapon; TaskShootAtEntity(chaser, playerPed, 1500, `FIRING_PATTERN_SINGLE_SHOT` hash); tasks[id] = 'Taser'; vehicleData.taserAt[id] = now. After ~1.6 s, return the chaser to the TaskGoToEntity chase (tasks[id] reset so the normal assignment re-issues). Holster the taser afterwards (switch back to sidearm) so a later hostile escalation uses a real weapon.
- Tackle: chaser within range, player speed > 2.0 m/s, cooldown, chance roll → SetPedToRagdollWithFall(playerPed, ms, ms+500, 1, fwd.x, fwd.y, fwd.z, groundZ, 0,0,0,0,0,0) where fwd is the CHASER's forward vector (suspect is driven forward and down). Optional small push. tasks[id]='Takedown'.
- Downed → cuff: whenever the player is down (IsPedBeingStunned(playerPed,0) or IsPedRagdoll(playerPed)) — from a taser, a tackle, a K9 bite, anything — and a living officer from this unit is within cuffRange (task the chaser TaskGoToEntity to close in), start a short "takedown hold": wait until the ragdoll ends or getUpGraceMs elapses, then call triggerArrest(chaser). If the player gets up and is > cuffRange + 2.5 m from the officer before the hold completes, abandon the hold and resume the chase.
- Wanted-level gating: taser only ≤ taser.maxWantedLevel; tackle ≤ tackle.maxWantedLevel; hostile (FootCombat) chasers never tase/tackle — they shoot, as today.
- Radio: one FenixPursuit line when a suspect is tased/tackled if a suitable announce helper exists (guarded); don't add new pursuit.lua API in this lane.
- Debug: Config.isDebug prints.

## F2. Chase tactics scale with wanted level  (client/client.lua + client/combat_bridge.lua)

Problem: SetTaskVehicleChaseBehaviorFlag(officer, 8, true) (boxing + some PIT) is hard-coded at every wanted level; a live 3-star test produced "a point-blank box-in almost immediately". A 1-star speeder is boxed/PIT'd exactly like a 5-star cop-killer.

Flags (from the native docs): 1 aggressive ramming, 2 ram attempts, 8 medium-aggressive boxing + a bit of PIT, 16 ramming (slightly less aggressive than 1-2), 32 stay back / no tactical contact (convoy-like).

Config.Driving.chaseTactics = {
    [1] = { 32 },        -- follow; no contact tactics for a minor offence
    [2] = { 32 },
    [3] = { 8 },         -- boxing, occasional PIT
    [4] = { 8, 16 },     -- boxing + ramming
    [5] = { 8, 2 },      -- end it now
}
- Global helper defined in client/combat_bridge.lua (loaded before client.lua): `function ApplyChaseTactics(ped, wantedLevel)` — sets every known flag {1,2,8,16,32} explicitly true/false per the table (unknown level → nearest defined lower level → {8}). Add 'ApplyChaseTactics' to the globals list in .luacheckrc.
- client.lua: call it where TaskVehicleChase is issued (VehicleChase transition) instead of the hard-coded flag 8, and re-apply when the wanted level changes during an ongoing chase (profile.chaseTacticsLevel ~= wantedLevel) — without re-issuing TaskVehicleChase.
- combat_bridge.lua: its server-driven vehicleChase path uses the helper with profile.wantedLevel if present else 3.
- Ambient pullover (client/ambient.lua) already uses 32 (calm) → 8 (escalate) after the fix phase; leave it.

## F3. Carjackings call in a real pursuit  (client/ambient.lua)

Implement the "CARJACK → PURSUIT WIRING" design at the bottom of /tmp/claude-0/-home-user-fenix-police/cea904fe-d3d3-56fd-ba43-39aa14aee901/scratchpad/audits/ambient.md (steps 1-5) on top of the fixed ambient.lua: victim calls it in after a short delay; prefer re-tasking an existing nearby patrol; else spawn 1-2 chasers out of view; hand off to the existing NPC pursuit state machine so it ends in the existing arrest tableau. Config.Ambient.carjackResponse = { enabled = true, chance = 0.75, reportDelay = {6, 12}, reuseRadius = 300.0, chasers = {1, 2} }.

## F4. Investigations can find the shooter  (client/witness.lua, client/investigate.lua, server/dispatch.lua [+ server/incident.lua if needed])

Implement "INVESTIGATION OUTCOMES DESIGN" at the bottom of /tmp/claude-0/-home-user-fenix-police/cea904fe-d3d3-56fd-ba43-39aa14aee901/scratchpad/audits/incident.md on top of the fixed code: self-fired flag on gunshot reports; server records suspects; investigating unit that sees a listed suspect visibly armed within spotRange with LOS reports it; server validates (unit owned by reporter, suspect listed, server-side distance) and applies the wanted level via the existing client SetWantedLevel event (max semantics); if the suspect is the investigating client's own player, the unit is promoted into the pursuit stack (PromoteAmbientUnit). Config.Investigate.spotRange = 40.0, Config.Investigate.exemptZones = { -- Ammu-Nation ranges: { coords = vector3(13.6, -1097.4, 29.8), radius = 25.0 }, { coords = vector3(821.7, -2163.4, 29.6), radius = 25.0 } } (verify these are the two Ammu-Nation shooting-range interiors: Pillbox Hill / Adam's Apple Blvd and Cypress Flats; if unsure, ship the list empty with a commented example). No gunshot reports or incidents are created from inside an exempt zone either.

## F5. Felony-stop surrender  (client/client.lua — surrender)

After the fix phase, surrender already: elects one arresting unit, makes others hold fire, has a timeout and a death exit. Add the presentation:
- Non-arresting units within ~45 m stop (BringVehicleToHalt / TaskVehicleTempAction brake) and their officers get out and cover the suspect from beside their car: TaskAimGunAtEntity(ped, playerPed, -1, false) with combat suppressed (passive relationship group, SetBlockingOfNonTemporaryEvents) — "guns on you, nobody fires". Transition-gated (issue once). Released when surrender ends (they re-board via the normal reboard path) or the arrest starts (escort logic takes over).
- A police heli present orbits above the suspect with its searchlight on (TaskHeliMission circle/attack-style hover around the player ped; search mission type used elsewhere in the file as reference) while surrendering; restored to its normal task when surrender ends.
- On-screen help text while surrendering: "Hands up. Officers are moving in — [H] to cancel" (BeginTextCommandDisplayHelp('STRING') / AddTextComponentSubstringPlayerName / EndTextCommandDisplayHelp(0, false, false, -1)), drawn each frame from the existing surrender thread, using the actual bound key name if the existing code exposes it (Config.ArrestSystem.surrenderHint string overrides; '' disables).

## F6. Arrest presentation  (client/client.lua — triggerArrest)

- Paired cuffing: the arresting officer holsters (SetCurrentPedWeapon(cop, `WEAPON_UNARMED`, true)), walks behind the player, and the pair plays `mp_arrest_paired` — cop: `cop_p2_back_left`, suspect: `crook_p2_back_left` (~3.5 s) with the suspect briefly attached to the cop for alignment (AttachEntityToEntity(playerPed, cop, 11816, -0.1, 0.45, 0.0, 0.0, 0.0, 20.0, false, false, false, false, 20, false) then DetachEntity), then the existing SetEnableHandcuffs walk. Every anim dict load bounded by a timeout; on any failure skip straight to the existing flow.
- Draw Config.ArrestSystem.bustedSubtitle under BUSTED (it is defined in config but never drawn).
- One "suspect in custody" radio line if FenixPursuit exposes a suitable announce helper (guarded).
- Config.ArrestSystem.pairedCuffing = true (false = current behaviour).

## F7. Units leave instead of vanishing  (client/client.lua — end of wanted)

When the wanted level ends by evasion/decay (NOT force cleanup, resource stop, arrest teleport, or a server cleanupAllPolice for a player who was never wanted), units should not pop out of existence in front of the player:
- siren off, officers on foot re-board (or are deleted if off-screen), drivers TaskVehicleDriveWander at a calm speed;
- each unit is moved out of spawnedVehicles/spawnedHeliUnits into a `departingUnits` table that the main loop never tasks;
- a departing ticker deletes each unit (through the existing server delete events, so FenixGuard ownership is respected) once it is off-screen AND > Config.Departure.despawnDistance (150 m) from the player, or after Config.Departure.maxSeconds (45 s) regardless;
- if the player becomes wanted again, departing units are NOT re-adopted; they keep leaving.
- heli: climb away (TaskHeliMission to a point 600 m away at altitude) then delete under the same rule.
- Config.Departure = { enabled = true, despawnDistance = 150.0, maxSeconds = 45 }. handleEndWantedDelete(force=true) keeps the immediate delete for every forced path; the 5-pass watchdog must not delete departing units early except on resource stop.
- Revive or delete the dead handleEndWantedTasks function accordingly (no dead code left).

## F8. Intercepting units  (client/client.lua — chase behaviour)

Port the server's dead intercept idea to client-owned drivers: half the ground units (vehicleData.interceptor assigned alternately at spawn/promotion) that are NOT within close-chase range and whose suspect is moving faster than Config.Driving.interceptMinSpeed drive to a road node ahead of the player's velocity (Config.Driving.interceptLeadDistance, 70 m; resolve with GetClosestVehicleNode so the target is on a road) instead of the player's position, so pressure comes from the front as well as behind. Re-path throttled by time AND distance like the existing DriveToCoord branch (road-node pool exhaustion is a real crash). Only with contact (FenixPursuit.hasContact()). Config.Driving.interceptors = true.

## F9. Night & lights-off stealth  (client/pursuit.lua)

In canSee (contact model): at night (GetClockHours() >= 21 or < 6) a ground observer's sight range is multiplied by Config.Pursuit.night.sightMultiplier (0.6) — unless the player's vehicle has its lights on (GetVehicleLightsState → lightsOn or highbeamsOn), which restores full range (Config.Pursuit.night.lightsOnMultiplier 1.0), or the player is on foot inside a lit area (keep simple: on foot = sightMultiplier). A police helicopter observer at night keeps full range when its searchlight is on (IsVehicleSearchlightOn). Config.Pursuit.night = { enabled = true, startHour = 21, endHour = 6, sightMultiplier = 0.6, lightsOnMultiplier = 1.0 }. Also add FenixPursuit.announceCustody() and FenixPursuit.announceTakedown(kind) radio helpers (kind = 'taser'|'tackle'|'k9') using the existing dispatch/radio mechanism and cooldowns, for F1/F6 to call.
