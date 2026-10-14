AUDIT REPORT — client/ambient.lua (+ data/ambient_points.lua, Config.Ambient)
(line numbers against commit 235a2cd; re-locate by content before editing)
All natives valid; all Config.Ambient keys exist. Director and radar loop bodies are pcall-wrapped; only refreshToolkitPoints() at ~1919 is outside (finding 21). An error on one scene aborts the whole tick for every scene, every second, until that scene is culled → wrap per-scene work in its own pcall.

1. [high][CONFIRMED] ambient.lua:1260, 1360, 1442 — In a `pursuit` scene the fleeing NPC suspect acts as the police officer.
   observerOf, catchPlayer, catchNpc, advanceNpcStop, standDownForTrafficStop assume vehicles[1]/peds[1] is the officer; in a pursuit scene slot 1 is the suspect's car and suspect (844, 849). enforceFromAllCops=true and cops>0 → pursuit scenes are armed. Player following an ambient chase >80mph: the suspect's car "clocks" them, ApplyWantedLevel runs, TaskVehicleChase(suspect, PlayerPedId()) makes the suspect turn on the player; scene becomes enforcing and survives the wanted sweep.
   Fix: trackPed when isCop appends to scene.copPeds; helper leadCop(s) returns first living cop ped + its vehicle; observerOf = vehicle-or-ped of leadCop; use leadCop in catchPlayer/catchNpc (catchNpc stores cop/copVeh in scene.chase for advanceNpcStop). Also stops dead officers from enforcing (scene.cops never decremented).

2. [high][CONFIRMED] ambient.lua:1726-1749 (borrowing 1450, release 352-360 and 1573-1583) — NPC radar scan hijacks any vehicle not driven by a player.
   Only filter is not IsPedAPlayer(driver): catches EMS/fire/investigation units, client.lua pursuit units incl. other players', other resources' mission vehicles, this file's own pursuit suspects/chasers (~100mph) and carjack getaways (67mph), helis/planes/boats. Then SetEntityAsMissionEntity(veh,true,true) steals it from its owning script; ClearPedTasks + BringVehicleToHalt, clipboard stop, then SetEntityAsMissionEntity(false)+no longer needed hands it to population manager. In OneSync world traffic often owned by another client → task natives ignored, target never stops, cop walks to a window 100m away; ClearPedTasks on a clone may emit clearPedTasksEvent (anticheats flag).
   Fix: add `and borrowable(veh, driver)`:
     local function borrowable(v,d) if IsEntityAMissionEntity(v) or IsEntityAMissionEntity(d) or IsPedDeadOrDying(d,true) or IsVehicleSirenOn(v) then return false end local k=GetVehicleClass(v) if k==14 or k==15 or k==16 or k==18 or k==21 then return false end if NetworkGetEntityIsNetworked(v) and not (NetworkHasControlOfEntity(v) and NetworkHasControlOfEntity(d)) then return false end return true end

3. [high][CONFIRMED] ambient.lua:339-344, 612-616, 1836-1840 — Player can drive off in a local, unlocked cruiser which is then deleted under them.
   stop cruiser empty with engine running; pursuit cop cars empty after officersOut; radar cop gets out during an NPC stop. Cull measures distance from vehicles[1] (the stationary civilian car); driving 320m away or reaching lifetime end DeleteEntity's the car the player is driving. Non-networked: other players see driver floating.
   Fix: after creating each cruiser SetVehicleDoorsLockedForAllPlayers(veh, true); in delete branches of destroyScene and tryPromoteScene: if GetVehiclePedIsIn(PlayerPedId(), false) == veh then SetVehicleAsNoLongerNeeded(veh) else DeleteEntity(veh) end. (Mind that officers must still be able to re-enter their own locked car — SetVehicleDoorsLockedForAllPlayers only affects players.)

4. [high][CONFIRMED] ambient.lua:1666 (+ client.lua:164-165) — radar catches run while the player is already wanted, each adds a star (ApplyWantedLevel ADDS). Scenes survive up to 1s at wanted onset and while director paused inside PromoteAmbientUnit (~5.5s per vehicle). With despawnWhenWanted=false, a star every 45s.
   Fix: if c.catchPlayers ~= false and GetPlayerWantedLevel(PlayerId()) == 0 and not playerIsOnDutyPolice() then. violations.lua cite() has the same gap (incident group owns violations.lua).

5. [med][CONFIRMED] ambient.lua:671-688 vs 1372 — advanceInbound cancels radar-catch chases: scene.inbound stays set after catchPlayer/catchNpc/stand-down; on arrival or 60s timeout TaskVehicleDriveWander replaces TaskVehicleChase (cop wanders off, siren on).
   Fix: scene.inbound=nil in catchPlayer and catchNpc; top of advanceInbound: if scene.enforcing or scene.chase then scene.inbound=nil return end.

6. [med][CONFIRMED] ambient.lua:1387, 1836-1840, 1981 — enforcing scenes never stand down and are deleted mid-chase (chases until expiresAt 130s then DeleteEntity right behind the player, or keeps chasing a no-longer-wanted player).
   Fix: catchPlayer sets scene.enforcedAt; wanted branch: once per scene PromoteAmbientUnit(ps.copVeh, ps.cop, {}) exempt from cap, on success remove car+cop from scene.vehicles/peds and clear enforcing/playerStop; not-wanted branch: if scene.enforcing and now-enforcedAt > 10000: ClearPedTasks(cop), siren off, TaskVehicleDriveWander(cop, copVeh, 16.0, 786603), enforcing/playerStop=nil, retired=true, releaseOnTeardown=true, expiresAt=now+25000; armed filter (1652) excludes retired.

7. [med][CONFIRMED] ambient.lua:1113 — carjack TaskEnterVehicle uses flag 16 (teleport into vehicle) instead of 8 (carjack ped from seat) → warp with no drag-out, or task fails and scene times out after 25s. Fix: TaskEnterVehicle(suspect, veh, 20000, -1, 2.0, 8, 0).

8. [med][CONFIRMED] ambient.lua:1285-1293 — IsWitnessed counts scenes with no officer (carjack scenes zero cops, observer = victim's car; pursuit scenes observe via suspect's car; stop scenes via civilian car; dead officers count) → violations.lua cites player with only a carjacker nearby. Fix: if scene.cops > 0 (better: leadCop exists) then use leadCop-based observerOf.

9. [med][CONFIRMED] ambient.lua:1066-1071 — after arrest escort the transport never drives off: suspect in back seat, scene released with officers still on foot and nobody driving; armed cops left as population peds next to driverless car.
   Fix: scene.copVehOf[cop]=copVeh at spawn; 'departing' phase: each cop TaskEnterVehicle(cop, copVehOf[cop], 15000, -1, 1.5, 1, 0); once seated or after 16s: siren off, TaskVehicleDriveWander(driver, v, 16.0, 786603); releaseOnTeardown=true, expiresAt=now+25000, scene.pursuit=nil.

10. [med][CONFIRMED] ambient.lua:1371-1374, 1434-1436 — pullover posture backwards: "calm" sets chase flag 8 (boxing/PIT); "escalation" rolls Config.Driving.aggression[1]=0.10-0.25 (≤ calm 0.15) and lengthens following distance 20→25m.
   Fix: calm SetTaskVehicleChaseBehaviorFlag(cop, 32, true); escalate: flag 32 false, flag 8 true, IdealPursuitDistance 8.0, aggression math.max(roll, 0.5). rollAggression crashes on documented single-pair form aggression={lo,hi} (indexes a number) — guard type(range)=='table'.
   (NOTE: the client.lua group is introducing a shared per-wanted-level chase-tactics helper; keep this local but consistent.)

11. [med][CONFIRMED] ambient.lua:1705-1744 — one scene can catch player and an NPC in the same tick (npcCatchers built from armed checking only scene.chase); radar cop re-tasked to chase the NPC; advanceNpcStop never runs (playerStop checked first 1648-1651); borrowed NPC stays mission entity until expiry. Fix (1742): if not scene.chase and not scene.enforcing and ...

12. [med][CONFIRMED] ambient.lua:2171-2191 and 374-378 (+ investigate.lua:113-118) — ClaimNearbyPatrolForInvestigation doesn't exclude enforcing/playerStop/chase (patrol chasing the player pulled to an investigation); handOffScene never releases scene.borrowed (leaks world-traffic mission entities; also on promotion).
   Fix: filter add `and not scene.enforcing and not scene.chase and not scene.playerStop`; move borrowed release (350-362) into releaseBorrowed(scene) called by destroyScene and handOffScene. (investigate.lua driver-leak fix → incident group.)

13. [med][CONFIRMED] ambient.lua:1874-1902, 1983 — maxPromotedPerOnset cap not applied within a convoy (3-car convoy → 3 promotions). Fix: tryPromoteScene(scene, budget) promote only while budget>0, decrement per success, delete the rest; caller passes maxPromoted - promotedThisOnset.

14. [med][CONFIRMED] ambient.lua:1670 — speeding catches in helis/planes/boats (no vehicle-class filter; 3D cone distance). Fix: k=GetVehicleClass(playerVeh); skip 14/15/16/21.

15. [med][CONFIRMED] ambient.lua:682-686, 786 — convoys split at first junction (each car independent wander). Fix: cars index>1 TaskVehicleEscort(car.cop, car.veh, ib.cars[1].veh, -1, car.speed, car.style, (cfg().convoySpacing or 9.0), 0, 20.0).

16. [med][CONFIRMED] ambient.lua:1836-1840 (expiry 697, 744, 1092) — moving scenes vanish in view at expiry (patrol/convoy/carjack never set releaseOnTeardown). Fix: in cullScenes before destroyScene: if expired and not tooFar and lead and IsEntityOnScreen(lead) then scene.releaseOnTeardown=true end.

17. [low][CONFIRMED] ambient.lua:1637 — interior guard returns before advancePlayerStop/advanceNpcStop → stops freeze while player in interior/tunnel MLO. Fix: move guard below armed-building loop / stop-advance calls.

18. [low][CONFIRMED] ambient.lua:223 — junction penalty checks flags & 8 (SWITCHED_OFF); JUNCTION is 1<<7. Fix: (flags & 128) ~= 0.

19. [low][CONFIRMED] ambient.lua:1659-1663, 1711 — lastNpcPos stale (not reset when nothing armed / no NPC catchers) → first scan after re-arm sweeps minutes-old segments up to 300m; reused handles → false catches. Fix: lastNpcPos={} at both early returns.

20. [low][CONFIRMED] ambient.lua:1686 — `scene.radarSpeed and nil or posted` always = posted. Fix: local postedArg = (not scene.radarSpeed) and posted or nil.

21. [low][LIKELY] ambient.lua:1784, 1919 — refreshToolkitPoints() outside director pcall; #list errors on non-table → kills director for session. Fix: if type(list)=='table' then n=n+#list end (also ~2053); wrap call at 1919 in pcall.

22. [low][LIKELY] ambient.lua:444, 525, 1684 — string speed from em_toolkit breaks radar every tick. Fix: scene.radarSpeed = tonumber(pointSpeed).

23. [low][CONFIRMED] ambient.lua:998-1003 — RequestAnimDict then immediately HasAnimDictLoaded → false first time → TaskHandsUp always. Fix: RequestAnimDict('random@arrests@busted') when entering giving_up (988 and surrender branch).

24. [low][CONFIRMED] ambient.lua:973-985 — on_foot re-issues TaskGoToEntity/TaskSmartFleePed every second (stutter). Fix: issue once on phase entry; re-issue only when GetScriptTaskStatus(ped, hash) indicates not running.

25. [low][CONFIRMED] ambient.lua:807-821, 930-946 — unknown pursuitOutcomes keys never resolve. Fix: pickPursuitOutcome skips kinds not in {bail, surrender, crash}.

MULTIPLAYER: everything ambient creates is local (isNetwork=false); each client runs its own director; cross-client effects: borrowing traffic owned by another client (#2), promotion networks a local car in place, stolen local cruiser makes driver invisible (#3).

CARJACK → PURSUIT WIRING (feature design, for the features phase):
 1. Refactor spawnPursuit (no behaviour change): addChasers(scene, suspect, suspectVeh, count, spawnPos, heading) from lines 856-877 appending to vehicles/peds/copPeds/copVehOf; beginNpcPursuit(scene, suspect, suspectVeh) from 879-890 setting expiresAt=now+pursuitLifetime and lastPursuitAt.
 2. advancePursuit iterates scene.copPeds instead of "every ped that isn't the suspect" (923, 973, 981, 1005) — otherwise carjack victim in peds[1] treated as officer.
 3. advanceCarjack: on entering fleeing set cj.reportAt = now + random(6,12)s (victim calls it in); fleeing branch: when now>=reportAt, cooldown ok (pursuitCooldownSeconds), getaway within nearbyRadius of player, random<carjackPursuitChance → (a) prefer an existing patrol/convoy scene within reuseRadius (300m) not enforcing/chasing/stopping: move its lead cop+car into the carjack scene, handOffScene(patrol) after deleting/releasing leftovers, siren on, TaskVehicleChase(cop, suspect) + flag 8; (b) else spawn 1-2 chasers out of view via FenixRoads.findSpawnPoint(carPos, {minDistance=60, maxDistance=140, towards=carPos, avoidVisible=true, reserve=false}) + addChasers; (c) beginNpcPursuit(scene, suspect, veh), scene.carjack=nil → advancePursuit runs (scene.pursuit set) → arrest tableau.
 4. Config: Config.Ambient.carjackResponse = { enabled=true, chance=0.75, reportDelay={6,12}, reuseRadius=300.0, chasers={1,2} }.
 5. Ship with #2's mission-entity filter.

Improvements: explicit scene roles + per-scene pcall + retireScene helper; multiplayer area ownership (lowest server ID owns a grid cell via GlobalState) to avoid duplicate procedural scenes; more realistic NPC pull-overs (85% pull over within 3-5s onto shoulder via TaskVehiclePark); start carjack/pursuit clocks only once player is 40-100m with LOS; region/model/livery from scene position not player's.
