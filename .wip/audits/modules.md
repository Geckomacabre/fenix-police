AUDIT REPORT — client modules: pursuit.lua, tactics.lua, roads.lua, backup.lua, morale.lua, jurisdiction.lua, livery.lua, tracker.lua, framework.lua, combat_bridge.lua
(line numbers are against commit 235a2cd; re-locate by content before editing)

Interface check: every Fenix*.X called from client.lua/ambient.lua/investigate.lua/ems.lua/fire.lua exists with compatible signatures/returns. Multi-return natives unpacked correctly. All Config keys exist or have in-code defaults. Only invalid native names are the two framework.lua ones.

1. [high][CONFIRMED] client/morale.lua:127-130 + 264-271 — Retreated unit re-breaks forever and is never released, permanently consuming a unit slot.
   On regroup, originalCrew and troubleSince are deliberately kept; next cycle assess() sees the same dead>0 / wounded>0 (health never regenerates) and troubleSince older than 25s → returns 'casualties'/'suppressed' immediately → beginRetreat again. ~53s cycle (3s flee + ≤15s entering + 35s regroup), forced "Unit disengaging" radio each time. While retreating, client.lua skips far-officer tracking (jumps to continueGroundOfficer) so unit never far-cleaned, yet counts in currentUnits (client.lua:1597) so never replaced. Over a long fight the response shrinks to zero.
   Fix: cooldownUntil = {}; in assess: if (cooldownUntil[vehNetID] or 0) > GetGameTimer() then return false end; on regroup: originalCrew[vehNetID]=nil; troubleSince[vehNetID]=nil; cooldownUntil[vehNetID]=now+60000. Better (matches config.lua comment's promise): if still broken at regroup, mark released[vehNetID]=true, expose FenixMorale.isReleased, and have client.lua delete the unit (same path as handleFarPeds) so maintainPoliceUnits backfills a FRESH unit ("relief").

2. [high][CONFIRMED] client/morale.lua:184, 219-224, 247, 251-256 — Retreating car never gets a driver, so "drive off" never happens.
   ClearPedTasksImmediately warps every officer out; tryBoard tries seats {2,1,-1,0} (rear first), survivors fill 2 and 1, GetPedInVehicleSeat(veh,-1)==0 → TaskVehicleDriveWander never issued. TaskEnterVehicle re-issued every 1s tick for anyone not seated (client.lua:2177-2181 documents this pattern leaves officers "walking on the spot"). Both officers pick the same free seat in the same tick. On policeb (2 seats) seats 2/1 don't exist.
   Fix: ClearPedTasks (not Immediately) and keep a live in-car driver in place, tasking TaskVehicleDriveWander directly; seat order {-1,0,1,2} filtered by seat <= GetVehicleMaxNumberOfPassengers(veh)-1 and IsVehicleSeatFree; per-record claimed[seat]; issue enter task once (if r.boarding[id] and GetScriptTaskStatus(ped, 0x950B6492) ~= 7 then return false end); in 'driving', if no driver, SetPedIntoVehicle(firstAliveOfficer, veh, -1) before wandering.

3. [high][LIKELY] client/tactics.lua:177 — Roadblocks/spikes almost never placed.
   IS_SPHERE_VISIBLE is a frustum test with no occlusion; candidates are sampled 120-300m straight along player heading = centre of chase camera view → nearly every candidate rejected. Fix: "visible" only if in frustum AND an unobstructed LOS ray from GetFinalRenderedCamCoord reaches it (StartShapeTestLosProbe flags 1|16, ignore PlayerPedId, loop GetShapeTestResult with Wait(0) — tactics thread so Wait is OK). Or only apply check under ~150m.

4. [high][CONFIRMED] client/tactics.lua:305,309,382 — Spike hit test is a sphere around the road centre line, not the strips.
   On 3+3 road radius = 3*3.5/2+2 = 7.25m but kerb-lane centre at 8.75m → driving over that strip pops nothing; swerving into inner oncoming lane (no strip) DOES pop. On 2+2 window ~±1.5m; at 50ms+ ticks above 30 m/s can tunnel. All six tyres burst at once. (Correct: only local player's vehicle checked.)
   Fix: per strip object and per wheel bone (wheel_lf/rf/lm1/rm1/lr/rr → tyre 0,1,2,3,4,5): local = GetOffsetFromEntityGivenWorldCoords(obj, GetWorldPositionOfEntityBone(veh, boneIdx)); burst that wheel when its across-strip coordinate changes sign vs last tick (swept) and |along| < halfLen (GetModelDimensions) and |z| < 1.0. Require GetPedInVehicleSeat(veh,-1)==PlayerPedId().

5. [high][CONFIRMED] backup.lua:88-93,120-128 + client.lua:1909,1936,1963,2269,2419 — Incident score saturates immediately and "officer down" announced when nobody was shot.
   reportOfficerDown called every 1s cycle for every dead officer (45s ground / 120s air) = +40/s, not once. reportSuspectArmed called once per unit per cycle (6 units → +48/s). IsPedArmed(ped,7) includes melee (use 6 = guns only). Drawing a knife at 3 stars → full +3 units in ~1s plus "Shots fired, officer down! All units respond." every 20s.
   Fix: downReported={} dedupe in reportOfficerDown (clear in reset()); rate-limit armed reports (once per second globally, or call once from maintainPoliceUnits); flag 6; only announceBackupRequest when an officer-down/taking-fire event happened inside the decay window (lastRealIncidentAt).

6. [med][CONFIRMED] morale.lua:101 — "Dead" derived from headcount, so non-death roster removals count as casualties.
   Foot-chase give-up (client.lua:3890-3895) and far cleanup (client.lua:2728) delete officers → 2-officer unit shows dead=1, fraction 0.5 → retreat 'casualties' (feeds #1).
   Fix: explicit FenixMorale.reportDeath(vehNetID, pedNetID) deduped and called next to reportOfficerDown; or FenixMorale.officerRemoved(vehNetID) decrementing originalCrew at non-death removal sites.

7. [med][CONFIRMED] morale.lua:120-125 — 'outnumbered' fires for every unit that STARTS with one officer.
   policeb numPeds=1: at 3+ stars with player holding any weapon incl. melee (flag 7), retreats first cycle and loops per #1.
   Fix: if original > 1 and currentCount <= 1 and wanted >= lvl and IsPedArmed(playerPed, 6) then.

8. [med][CONFIRMED] jurisdiction.lua:149-183 + client.lua:1541-1556 — Handoff empties the pursuit, flaps at borders, false-fires at pursuit start.
   Every unit retreats on crossing yet still counts in maxUnits → no new-region units spawn; ~53s later same old-agency units return. No dwell/cooldown: road along a border toggles every second (forced handoff radio each flip + mass retreat). beginRetreat sends forced announceRetreat per unit (6 units → 6-7 notifications). lastRegion never reset and checkCrossing only runs while wanted → next pursuit opens with spurious "Suspect crossing into countryside"; radio prints internal key (sandyShores).
   Fix: dwell timer (pendingRegion/pendingSince ~8s); FenixJurisdiction.reset(){lastRegion=nil} called next to FenixPursuit.reset() at client.lua:5670; RELEASE outgoing units instead of retreating (delete out of sight, remove from spawnedVehicles) so new-region units backfill; skip announceRetreat when reason=='jurisdiction' and rate-limit otherwise; human-readable region names.

9. [med][CONFIRMED] pursuit.lua:581-585 — With empty observer set the contact state freezes.
   Retreating units skip noteObserver (client.lua:1945 runs before 1955). With no heli every observer times out in 4s; thread idles: contact.active stays true → hasContact() true, tactics keep placing roadblocks, tracker removal blocked; a search never gives up.
   Fix: when next(observers)==nil still run state machine with seen=false; only skip ray loop; keep tracker/gunfire overrides, loseContactMs and giveUp transitions.

10. [med][LIKELY] tracker.lua:113-141 vs server/tracker.lua:41-45 — Tracker can't be removed through the designed flow.
   Server requires requester in driver seat but ox_target prompt + mini@repair anim is on-foot → after 12s bar server refuses silently. Ambient cruisers are non-networked (ambient.lua:308) → NetworkGetNetworkIdFromEntity returns 0 → server returns early; those count as tracked forever.
   Fix (server): allow driverPed == ped or (driverPed == 0 and #(GetEntityCoords(ped)-GetEntityCoords(vehicle)) < 4.0), TriggerClientEvent the result. Fix (client): hasTracker returns false when not NetworkGetEntityIsNetworked(vehicle).

11. [med][CONFIRMED] combat_bridge.lua:43,49,55,71 — Wrong player can be targeted.
   GetPlayerFromServerId returns -1 when target not in owner's scope; GetPlayerPed(-1) = local player's ped → owning client's own player gets heli-chased/combat-tasked/rammed.
   Fix: local pl=GetPlayerFromServerId(id); local t = pl ~= -1 and GetPlayerPed(pl) or 0; if t ~= 0 and DoesEntityExist(t) then ... end. Also guard if not NetworkDoesEntityExistWithNetworkId(pedNetID) then return end.

12. [med][LIKELY] tactics.lua:237-249 — Roadblock cars spawn overlapping.
   Parked broadside one per lane at 3.5m spacing but cars ~5m long → interpenetrate ~1.5m → physics scatters/launches block.
   Fix: mn,mx = GetModelDimensions(hash); len = mx.y-mn.y; n = math.max(1, math.floor(span/(len+0.4))); space n cars evenly across span = lanes*laneWidth; alternate ±1.5m along-road stagger and/or yaw ±20°.

13. [med][LIKELY] tactics.lua:336-338 — Strips probably lie along the lane instead of across it.
   p_ld_stinger_s long on local Y; SetEntityHeading(obj, road.heading) points strips down the lane.
   Fix: mn,mx=GetModelDimensions(hash); SetEntityHeading(obj, ((mx.y-mn.y)>(mx.x-mn.x)) and (road.heading+90.0)%360.0 or road.heading).

14. [med][LIKELY] roads.lua:386-391,403-405 + tactics.lua:72 — Lane geometry ignores the median, assumes symmetric lanes.
   GetClosestRoad's 6th return is the median gap between directions, not road width; stored as `width` and unused. Lanes centred on node line; on two-way links GTA lays lanes outward from the median → 2+1 roads put an inner A-lane car on the centre line; boulevards with medians place cars/strips on the median.
   Fix (two-way link): offA(k)=w/2+(k-0.5)*lw, offB(k)=-(w/2+(k-0.5)*lw), k=1 innermost. Keep centred formula for one-way links. Verify with /fenixroads here.

15. [med][LIKELY] tactics.lua:162-188 — Placements not checked against the player's actual route.
   Straight-line samples from player heading; on curves the closest road can be a parallel/crossing street or overpass. Tactics also run when player in heli/plane/boat.
   Fix: reject when CalculateTravelDistanceBetweenPoints(player, road.center) > dist*1.4 (or walk nodes with GetNthClosestVehicleNodeFavourDirection); skip when IsPedInAnyHeli/Plane/Boat.

16. [low][CONFIRMED] backup.lua:144-148 — Heli backup bonus never triggers: incidents.heli never written, maxBonusHeliUnits dead. Fix: bonusUnits('heli') uses currentScore('ground') with heli thresholds, or pass kind from heli/air loops.

17. [low][CONFIRMED] framework.lua:72-74 — Invalid feed natives; if reached, throws inside caller (e.g. pursuit contact thread via dispatch()) killing it. Fix: BeginTextCommandThefeedPost('STRING'); AddTextComponentSubstringPlayerName(msg); EndTextCommandThefeedPostTicker(false, true).

18. [low][CONFIRMED] pursuit.lua:245 — LOS flags 17 = map(1)+objects(16), not vehicles(2); trucks/traffic never block sight despite comment. Fix: use 19 with the observer's own vehicle excluded (ignore entity); separately skip canSee once `seen` is true (pruning/blips still run).

19. [low][LIKELY] pursuit.lua:254 — IsPedShooting true ~1 frame, sampled every 250ms → most single shots missed; gunfire-reveal unreliable. Fix: Wait(0) thread only while observers exist sets lastShotAt; makingNoise checks now-lastShotAt < 500.

20. [low][CONFIRMED] pursuit.lua:420-423 — sirenWanted() returns contact.active which never changes when Config.Pursuit.enabled=false → sirens stay muted. Fix: if cfg().enabled == false or cfg().quietSearch == false then return true end.

21. [low][CONFIRMED] tactics.lua:416-418 — Roadblock car with player inside skipped by cleanup but stays a mission entity forever. Fix: else branch SetEntityAsNoLongerNeeded(veh).

22. [low][LIKELY] morale.lua:144 — clearUnit only called at client.lua:2196; removals at client.lua:2623, 2728, 3898 leave retreating/originalCrew/troubleSince behind; stale handles can be reused (TaskVehicleDriveWander on an unrelated vehicle's driver), recycled netID inherits old crew baseline. Fix: call FenixMorale.clearUnit(vehNetID) at each spawnedVehicles[vehNetID] = nil; in tickRetreats drop records whose vehicle no longer exists.

23. [low][LIKELY] roads.lua:654-667,768 — Synchronous CalculateTravelDistanceBetweenPoints up to 24×/pass ×3 passes in one frame → spawn hitches. Fix: score first then reachable() on top 3 only, or Wait(0) every few samples.

24. [low][CONFIRMED] framework.lua:88-104 — GetClosestVehicle miswired: qb's GetClosestVehicle(coords, vehicleList) passed maxDistance as list → pcall fails every time; native fallback includes the player's own car → heli crew on foot (client.lua:2340) can be tasked to enter/jack the player's car. Fix: drop qb call; skip GetVehiclePedIsIn(PlayerPedId(),false) and vehicles with a player driver.

Improvement opportunities:
1. PIT/ramming escalation — hook VehicleChase transition client.lua:2079-2083 and combat_bridge.lua:73-74; choose chase-behaviour flags by wanted level (today flag 8 always). At 4-5 stars USE_CONTINUOUS_RAM (128)… gate on FenixPursuit.hasContact() and player speed.
2. Intercept/boxing-in — port server's alternating intercept lead (server.lua:150-160, interceptLeadDistance) to client-owned drivers in the DriveToCoord branch (client.lua:2056-2069); spawn one unit ahead via FenixRoads.findSpawnPoint.
3. Heli spotlight & night perception — heli pilot branch client.lua:2306-2325 + pursuit.lua canSee; at night SetVehicleSearchlight and sweep over lastKnown during HeliSearch; scale ground sightRange at night when player's lights are off.
4. Rolling roadblock — tactics driver thread; TaskVehicleEscort 2-3 existing units ahead on multi-lane roads.
5. BOLO-based re-acquire — extend sight range while FenixPursuit.tells().vehicle is still true.
