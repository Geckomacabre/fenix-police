AUDIT REPORT — client/client.lua lines 1-2100 (wanted API, stuck monitor, stolen vehicles, heli/air/ground spawn responses, combat profile, PromoteAmbientUnit, maintainPoliceUnits, driving profiles, handleChaseBehavior)
(line numbers against commit 235a2cd; re-locate by content before editing)
All natives valid; arg counts checked.

1. [critical][CONFIRMED] client.lua:1641 (+ server.lua heli/air early returns) — once 5 heli requests go unanswered, no helicopter spawns for the rest of the wanted episode.
   maxHeliUnitsPerLevel[2]=1 but every polHelis entry has wantedLevel>=3 (milHelis 4). At 2 stars client sends spawnPoliceHeliNet every cycle; getRandomAirUnit returns nil; server returns without spawnPoliceHeliNetResponse. After 5 cycles pendingHeliSpawns == MAX_CONCURRENT_SPAWNS; only reset in handleEndWantedDelete → escalating to 3-5 stars brings no heli. Same for air.
   Fix: server replies nil,nil on every exit path (SERVER group). Client: (a) don't send a request when no table entry has wantedLevel <= level; (b) timestamp pending requests and expire them after ~15s; (c) response handlers treat nil vehNetID as failure and decrement pending.

2. [high][CONFIRMED] client.lua:1596-1611, 1635-1645, 1671-1681 — unit counts ignore in-flight requests → caps exceeded (4 stars max 2 helis: cycle 1 sends 2; server heli spawn ≥1.7s; cycle 2 counts 0, sends 2 more; cycle 3 one more → 5 helis). Ground same when Config.Response.enabled=false or spawn > unitInterval.
   Fix: currentUnits = n + pendingGroundSpawns; currentHeliUnits = n + pendingHeliSpawns; currentAirUnits = n + pendingAirSpawns.

3. [high][CONFIRMED] client.lua:111, 1530 — disableAIPolice never gates spawning → Config.onlyWhenPlayerPoliceOffline does nothing (fork changed UpdateDispatchServices to SetMaxWantedLevel(5); comment ~3230 says spawning still skipped but neither main loop nor maintainPoliceUnits checks it). Config.Toggles (enabled, heliUnits, airUnits, …) never read anywhere.
   Fix: top of maintainPoliceUnits: if disableAIPolice == true or (Config.Toggles and Config.Toggles.enabled == false) then return end; gate heli/air blocks on Toggles.heliUnits/airUnits (read Config.Toggles to see which keys exist and honour each sensibly) — do NOT delete Config.Toggles.

4. [high][CONFIRMED] client.lua:1540-1557 (+ jurisdiction.lua, morale.lua) — region crossing pulls whole response out ~50s; stale lastRegion fakes a crossing at pursuit start.
   (MODULES group changes jurisdiction to RELEASE units via FenixMorale.release + adds FenixJurisdiction.reset(); CLIENT group: call FenixJurisdiction.reset() in the pursuit-over branch next to FenixPursuit.reset(); exclude retreating/released units from currentUnits; handle released units — see API CONTRACT.)

5. [high][CONFIRMED] client.lua:349-535 IsVehicleStuck/GetVehicleUnstuck — beyond luacheck's playerPed:
   (a) stuckAttempts[vehNetID] < max compares nil with number when stuck on very first check (counter only set in MonitorVehicle's not-stuck branch) → error kills that unit's MonitorVehicle thread.
   (b) after the sequence, TaskVehicleChase(driver, nil→0) gives no valid task; officerTasks still 'VehicleChase'/'DriveToCoord'; handleChaseBehavior only re-tasks on status change → wedged car near player sits idle forever.
   (c) fires on units stopped on purpose: speed<0.2 for 8s while wanted includes ticket-stop units halted with BringVehicleToHalt (~5015, ~5040), surrender approach (~3570), unit parked at last known position, VehicleChase behind a stopped player → cruiser reverses/swerves next to the player every ~13s.
   (d) hijacks player's car: if player steals and parks a cruiser, "driver" is the player → ClearPedTasks + TaskPerformSequence drives the player's car.
   Fix: stuckAttempts[id] = stuckAttempts[id] or 0; local playerPed = PlayerPedId(); return early if IsPedAPlayer(driver), any ticket/surrender/arrest/aftermath flag set, FenixMorale.isRetreating(vehNetID), or player within ~25m; replace direct TaskVehicleChase with officerTasks[driverNetID] = 'Unstuck' so the main loop re-tasks properly.
   WARNING: applying only the playerPed fix without (c) guards makes things worse (units would actually ram stopped/surrendering players).

6. [high][CONFIRMED] client.lua:1919-2121 — unit whose driver dies never drives again; dead officers never skipped by tasking code.
   Driver killed in seat: corpse in seat -1 for 45s receiving driver tasks; when deleted, passengers stay passengers (attribute 3=false keeps them seated); nobody moves to -1 → unit parked forever, counts toward maxUnits. Dead officer on foot (often the foot chaser = driver) goes into reboard branch; after reboardPatience (12 cycles) SetPedIntoVehicle warps the corpse into seat -1. Corpses fire rearm/unlock events every cycle.
   Fix: after FenixBackup report: if IsPedDeadOrDying(officer, true) then goto continueGroundOfficer end; in passenger branch, if seat -1 empty or holds a dead ped, TaskShuffleToNextVehicleSeat the first live passenger (or exit + re-enter seat -1) and reset its officerTasks entry.

7. [high][CONFIRMED] client.lua:2127-2171 — officers teleport into the passenger seat of the cruiser the player stole (player jacks cruiser; handleFootChase returns false since player in vehicle; on-foot officer hits "car still exists" branch, picks seat 0; after 45m/12 cycles SetPedIntoVehicle(officer, stolenCar, 0); passenger branch TaskCombatPed point-blank). unlockOfficerVehicle refused by FenixGuard every cycle → console spam.
   Fix: treat polVehicle == GetVehiclePedIsIn(playerPed,false) or IsPedAPlayer(GetPedInVehicleSeat(polVehicle,-1)) as "car gone": officer on foot pursuit/combat with attribute 3 = true; mark unit stolen (vehicleData.stolen = true) and stop reboard/unlock attempts.

8. [high][CONFIRMED] client.lua:1876-1889, 2128-2198 — wrecked/flipped/undriveable cruisers never abandoned (no IsEntityDead/IsVehicleDriveable/IsVehicleStuckOnRoof check): exploded wreck → officers walk back, warped in after 12s; car on roof → crew stays inside (attribute 3 re-forced false each cycle); counts toward cap until player >500m for 45s. If car truly deleted, early return at ~1886 makes "Car gone" branch (~2187) unreachable → those officers never processed/far-tracked again.
   Fix: at top: if vehicle dead/undriveable/stuck on roof: attribute 3 = true, TaskLeaveVehicle + combat/foot chase for live officers; vehicleData.abandoned = true and exclude from currentUnits; when NetToVeh fails, handle officers on foot instead of returning.

9. [high][LIKELY] client.lua:169-173, 206-210 — ApplyWantedLevel/SetWantedLevel clear wanted, Wait(10), then set again → watchdog (500ms) and main loop (1000ms) see 0 ~3-6% of the time per call: watchdog runs handleEndWantedDelete (deleting every unit mid-chase); main loop resets pursuit/tactics, closes spawnGate, reports wanted=false. SetWantedLevel clears+re-sets even when level unchanged.
   Fix: never clear. ApplyWantedLevel: cur=GetPlayerWantedLevel(PlayerId()); new=math.min(Config.MaxWantedLevel or 5, cur+level); if new>cur then SetPlayerWantedLevel(PlayerId(),new,false); SetPlayerWantedLevelNow(PlayerId(),false) end. SetWantedLevel: if level<=cur then return end. No thread/Wait. Use GetVehiclePedIsIn(ped,false) not last vehicle. (Read the existing functions fully first: preserve police-protection guard and any other side effects.)

10. [med][CONFIRMED] client.lua:1896-1942 — after a morale/jurisdiction retreat, tasks never refreshed: officerTasks keeps pre-retreat values; when retreating clears, transition-gated re-tasking skips VehicleChase/DriveToCoord(<15m)/ToLastKnown drivers → wander forever; passengers at 'CombatPed' never fight again.
   Fix: detect retreating true→false transition (vehicleData.wasRetreating), set every officerTasks[ped]='Regroup' and profile.lastDriveTarget=nil; handle vacant driver seat as in #6.

11. [med][LIKELY] client.lua:701-705, 807-811, 1190, 1334 — initial task statuses assume tasks never applied: heli pilot starts 'HeliChase' though real TaskHeliChase came from server's dispatchCombatProfile to NetworkGetEntityOwner (-1/server for fresh entity; non-owners ignore); helis often spawn outside 424m scope; ownership migration drops tasks. If contact already exists, handleHeliChaseBehavior never issues TaskHeliChase → heli idles. Same 'PlaneChase'; promoted ambient driver marked 'VehicleChase' while its real task is drive-to a frozen point.
   Fix: initialise every status to 'Spawned'; re-issue tasks when GetScriptTaskStatus(...) == 7 (no task running) — at least for the driver/pilot primary task.

12. [med][CONFIRMED] client.lua:1909, 1935-1936, 1962-1963 — backup scoring over-called: reportOfficerDown every cycle while corpse listed (45s); reportSuspectArmed once per unit per cycle.
   (MODULES group makes backup.lua idempotent internally; CLIENT group: vehicleData.reportedDown[pedNetID] report once; move reportSuspectArmed to main loop once per cycle.)

13. [med][CONFIRMED] client.lua:2048-2083 — 45m chase/drive-to switch has no hysteresis; 15m re-path threshold fails at speed (>54 km/h → new TaskVehicleDriveToCoord every second for every in-contact unit >45m back — the "Pool Full, Size == 20" crash load); units around 45m flip every cycle (stutter).
   Fix: while inContact, TaskVehicleChase at any range (or with hysteresis: enter chase under 60m, leave over 120m); otherwise throttle drive-to by time (≥3-4s) in addition to distance.

14. [med][CONFIRMED] client.lua:620, 734 → server — server trusts spawn table (SERVER group fixes; CLIENT group: after server derives table itself, client may keep sending the table but server ignores it — no client change required unless convenient; keep compatible).

15. [med][LIKELY] client.lua:1273-1371 (+ :3132, server.lua:222-235) — stale server cleanup broadcast deletes units right at wanted onset.
   Fix: cleanup handler: if GetPlayerWantedLevel(PlayerId())>0 or isSurrendering or isBeingArrested then return end.

16. [med][LIKELY] client.lua:571-590 — abandoned stolen cruisers out of OneSync scope (>~424m) forgotten → server entity lives forever. Fix: send deleteSpawnedVehicle for every entry and let server's resolve() decide (gone or occupied).

17. [low][CONFIRMED] client.lua:86-87, 97, 501 — per-netID state never reset; OneSync recycles IDs: stuckAttempts[id]=999 persists (later unit never stuck-monitored); deadPeds/farOfficers entries survive handleEndWantedDelete → frozen timer resumes next pursuit and calls deleteSpawnedPed(id) on whatever ped now has that ID (live officer). Fix: reset all in handleEndWantedDelete.

18. [low][LIKELY] client.lua:1070, 631, 745 — spawnGate only checked when a spawn handler starts; handlers yield for seconds → spawn registers after cleanup → orphan cruiser with siren on while not wanted. Fix: re-check spawnGate and wanted level just before inserting into tracking tables; delete entities (via the normal server delete events) if either fails.

19. [low][CONFIRMED] client.lua:1709-1714, 1745 — documented flat {min,max} form for Config.Driving throws: ability={0.6,0.9} → levelValue returns a number, range[1] errors every cycle (main-loop pcall hides it but aborts the rest of that cycle's tasking). Fix: accept a flat pair or a number in randRange/officerDrivingProfile (and levelValue callers generally).

20. [low][CONFIRMED] client.lua:1291-1300 — PromoteAmbientUnit silently drops passengers that fail to network, but ambient.lua marks them promoted → leak; promoted peds never get spawn path's SetPedFleeAttributes(0,false) and combat attributes 0/1/5 (~1130-1134). Fix: delete non-networked passengers inside PromoteAmbientUnit (or return adopted list) and apply base attributes to promoted peds.

21. [low][LIKELY] client.lua:303-325, 674-676 — heli spawn point ignores terrain height and network scope: z = player z + 150-200 → spawn inside hills; offsets up to ~707m → out of scope; NetToVeh fails; searchlight never on. Fix: sample by angle+distance (≤400m), z = max(playerZ, GetHeightmapTopZForPosition(x,y)) + h; turn searchlight/engine on once client owns vehicle (retry in heli loop).

22. [low][CONFIRMED] client.lua:2114-2121, 2173-2179 — reboarding officers get loadout every cycle (armour re-rolled every second; riot units +80 armour per tick; forced weapon switch); unlock events every cycle; rearm events for corpses. Fix: apply loadout once on transition to 'Reboarding'.

23. [low][CONFIRMED] client.lua:189, 221 — net events call exports['fenix-police'] by hard-coded name → renamed folder silently breaks server-driven wanted levels. Fix: call the local functions directly.

24. [low][CONFIRMED] client.lua:2004, 2041, 2045, 2068, 2081, 2105, 2111, 2124, 2167, 2184 — handleChaseBehavior re-indexes spawnedVehicles[vehNetID] after yielding; cleanup during yield → nil index error aborting the main-loop cycle. Fix: use the vehicleData local throughout.

Improvements: GetScriptTaskStatus-based re-issue instead of trusting cached status; chase behaviour flags by wanted level (32 hang back 1-2, 8 box/PIT at 3, ramming 4-5) — FEATURES phase; FenixPursuit.targetCoords returns live position before first contact contrary to its "dispatch position" doc (snapshot at wanted onset) — modules; keep response at strength (exclude retreating/abandoned/wrecked from counts; release out-of-view units); NetworkDoesEntityExistWithNetworkId pre-check before NetToPed retry loops (600ms per missing ped per cycle in handleChaseBehavior and checkDeadPeds); planes spawn at zero airspeed (SetVehicleForwardSpeed + retract gear on owning client); HATES_PLAYER group makes hostile units engage every nearby player, not just the wanted one.
