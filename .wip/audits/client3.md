AUDIT REPORT — client/client.lua lines 4330-6156 (arrest, wasted, tickets/pull-over, aftermath, main thread, cameraman thread, registry reporting, investigation promotion)
(line numbers against commit 235a2cd; re-locate by content before editing)
Compiles under luac5.4 once backtick replaced. All natives valid; all Config keys exist. MAIN THREAD body is pcall-wrapped (cannot die) — problems are logic errors.

1. [high][CONFIRMED] client.lua:4336-4625 and 5526/5646-5657 — failed/stalled arrest locks player + police for the session; the safety-net can never run.
   The else branch resetting isBeingArrested/isSurrendering only runs when `wantedLevel > 0 or isSurrendering or isBeingArrested` is false → dead while either flag true. Arrest thread has no pcall and three unbounded waits: HasAnimDictLoaded (4343), IsScreenFadedOut (4582), IsScreenFadedIn (4622). Another resource fading in during fade-out, or an error in handleEndWantedDelete, leaves isBeingArrested=true forever → controls disabled (3487), screen can stay black, maintainPoliceUnits never runs (5618), triggerArrest and H return immediately, every unit held by handleSurrenderApproach. triggerTicket (4874-4963) same pattern for isBeingTicketed.
   Fix: wrap thread body in pcall (cam declared outside); always cleanup afterwards: SetTimeScale(1.0); StopScreenEffect('DeathFailOut'); if cam then RenderScriptCams(false,false,0,true,true); DestroyCam(cam,false) end; SetEnableHandcuffs(ped,false); FreezeEntityPosition(ped,false); if not IsScreenFadedIn() then DoScreenFadeIn(500) end; isBeingArrested=false. Bound every wait with waitUntil(f, ms). arrestStartedAt; main-loop watchdog: if isBeingArrested and now-arrestStartedAt > 90000 then reset. Same treatment for triggerTicket/isBeingTicketed.

2. [high][CONFIRMED] client.lua:5618 (with 3439/3464) — surrendering before any unit has spawned means no unit ever spawns.
   maintainPoliceUnits skipped while isSurrendering; surrender thread re-pins wanted to 1 every 250ms with controls disabled; Config.Response.initialDelay[1]=35s → H before first unit arrives = hands up forever. Same if only unit culled by handleFarPeds/checkDeadPeds.
   Fix: if not (isBeingTicketed or ticketWrapUp or isBeingArrested) and (not isSurrendering or next(spawnedVehicles) == nil) then maintainPoliceUnits(...) end. Also skip the response initial delay while surrendering (a surrendering suspect should get a unit promptly), and add a surrender timeout (e.g. 120s with no unit → cancel surrender with a notification).

3. [high][CONFIRMED] client.lua:5254-5260 and 5341-5347 — after player goes down, officers on foot keep shooting them.
   holdSceneWithOfficer does `if vehicle == 0 then return end` before ClearPedTasks → foot officers with TaskCombatPed ('FootCombat', 3963) never cleared. standDownOfficer turns off attribute 46, but 46 is CA_CAN_FIGHT_ARMED_PEDS_WHEN_NOT_ARMED; AlwaysFight is 5 (set true at spawn ~1133) never cleared. Last-stand player still alive → foot officers keep firing through field revive.
   Fix: standDownOfficer add SetPedCombatAttributes(ped, 5, false); holdSceneWithOfficer handle on-foot: ClearPedTasks(ped); TaskStartScenarioInPlace(ped,'WORLD_HUMAN_COP_IDLES',0,true); return; set vehicleData.officerTasks[pedNetID]='Standby'. Seated branch runs standing scenario on seated ped (no-op) — drop it or TaskLeaveVehicle first.

4. [high][CONFIRMED] server/server.lua:1370-1379 fieldRevive unchecked — SERVER group owns this fix (see server.md #2).

5. [high][LIKELY] client.lua:4331 (with 3525, 2223) — arrest never orders units to stop shooting.
   While isBeingArrested, handleSurrenderApproach returns true at first line and handleHeliChaseBehavior returns early — both leave existing tasks: ground passengers 'CombatPed', other units' foot officers 'FootCombat', heli crew 'CombatPed' keep firing at the cuffed player during escort + BUSTED. If player dies, WASTED starts on top of BUSTED (two cams, competing SetTimeScale; BUSTED's RenderScriptCams(false) kills WASTED's cam).
   Fix: at start of arrest thread, for each officer in spawnedVehicles/spawnedHeliUnits/spawnedAirUnits whose task is 'CombatPed' or 'FootCombat': ClearPedTasks(p); SetPedRelationshipGroupHash(p, ensurePassiveGroup()); task='Standby'. Optionally SetEntityInvincible(playerPed,true) for the duration, reset in cleanup. Skip WASTED while isBeingArrested. (Outside slice: while isSurrendering, units beyond approachDistance fall through to normal chase/combat code — check and hold fire.)

6. [medium][CONFIRMED] client.lua:4390-4450 — escort can seat the player into a missing/taken seat (KNOWN LIMITATION in docs).
   policeb (2 seats) in wanted-1 pool with numPeds=1; IsVehicleSeatFree(veh,2)/(veh,1) fail; fallback `or 2` → TaskEnterVehicle to non-existent seat. Full riot/fbi2 → enter occupied seat = jack an officer. Ignores bikes and moving cars. Officers chosen to converge may still be seated (TaskGoStraightToCoord no-op).
   Fix: escortSeat(veh): nil for bikes/quads (IsThisModelABike/IsThisModelAQuadbike); for s=1, GetVehicleMaxNumberOfPassengers(veh)-1 do if IsVehicleSeatFree(veh,s) then return s end end; nil. Build candidates {veh,dist} from spawnedVehicles with dist <= escortMaxVehicleDistance, GetEntitySpeed(veh) < 1.0, escortSeat ~= nil; sort; take first; none → skip boarding, cinematic on foot. Re-check seat before entering; TaskEnterVehicle directly with walk speed (navmesh). On timeout: if IsVehicleSeatFree(veh,seat) then TaskWarpPedIntoVehicle(playerPed,veh,seat) else ClearPedTasks(playerPed) end. ClearPedTasksImmediately(playerPed) before station teleport (~4610) so player is out of the car handleEndWantedDelete(true) deletes. Seated converging officers: TaskLeaveVehicle first.

7. [medium][CONFIRMED] client.lua:5300-5320 — field revive succeeds even if medic never reached the player; nearbyGroundOfficers includes seated officers (revived by officer sitting in car 50m away); kneel scenario placed inside the body.
   Fix: if seated TaskLeaveVehicle(medic, veh, 256) wait ≤4s; approach with TaskFollowNavMeshToCoord(medic, x, y, z, 2.0, 15000, 1.0, 0, 0.0); after loop if #(medic - player) > (c.reviveRange or 8.0) then return (skip roll, keep holding); kneel ~0.8m to the side.

8. [medium][CONFIRMED] client.lua:5539 — shots mostly missed: IsPedShooting true only on fire frames; main loop samples once per 1000ms. playerHasShot / provokePolice() mostly missed (ticket denyAfterShooting, response-delay skip, chase hostility all read it).
   Fix: dedicated thread: while true: if wanted>0 then if IsPedShooting(PlayerPedId()) then playerHasShot=true; provokePolice() end; Wait(0) else Wait(500) end. Remove 5539 check. (Coordinate: pursuit.lua has the same issue — modules group.)

9. [medium][CONFIRMED] client.lua:4928-4962 — crimes during ticket wrap-up wiped: ticketWrapUp lasts ≤12s+6s with chase/heli/air/maintainPoliceUnits suppressed, then wanted cleared unconditionally.
   Fix: capture stopLevel at thread start; replace 12s wait and dispersal Wait with polling loops that break if GetPlayerWantedLevel(PlayerId()) > stopLevel or playerHasShot; only clear wanted when not escalated; always ticketWrapUp=false.

10. [medium][LIKELY] client.lua:5064-5068 and 4939 — two officers can exit; walker re-picked every tick (both may walk); wrap-up hardcodes seat -1 in TaskEnterVehicle → if passenger was walker, driver seat taken, can't board, car drives off, he's deleted in view. handleSurrenderApproach ~3590 same double-exit bug.
   Fix: before tasking exit check whether any task already 'ExitForTicket'/'ApproachWindow'; restrict walker to that officer; on wrap-up pick free seat (-1 if free else first free passenger seat).

11. [medium][CONFIRMED] client.lua:5756-5816 — "cameraman" thread useless and expensive.
   SetPedAsCop(cameraman) missing toggle (nil→false, never a cop); created pedType 0. `if theDriver then` always true (0 truthy) → empty parked cruisers, ambulances, fire trucks, player's stolen cruiser all get one. Every 200ms new thread + CreatePed/DeletePed per class-18 vehicle in pool; no RequestModel.
   Fix: remove the thread (pursuit.lua owns contact) — CHECK FIRST what it was for (read its comments) and whether anything depends on it; if it provided "police vehicles report the player" behaviour that pursuit.lua doesn't, gate behind a config flag default off with the listed fixes (only spawnedVehicles, driver ~= 0 and not IsPedAPlayer, RequestModel once, CreatePed(6,...), SetPedAsCop(ped,true), reuse one ped per vehicle).

12. [medium][CONFIRMED] client.lua:5570-5589 and 5684-5690 — downed in car with NPC: wanted never cleared; aftermath hold can get stuck on.
   otherPeds counts any ped incl. NPCs (comment says players only). Recovery + hold cap only checked in not-wanted else branch; after hospital respawn with stars set, pursuit resumes with aftermath.active true → handleEndWantedDelete no-ops; server aftermathHolding blocks global cleanup for everyone.
   Fix: pedInSeat ~= 0 and pedInSeat ~= playerPed and IsPedAPlayer(pedInSeat); wanted branch not-incapacitated path: if aftermath.active then endAftermath() end; aftermath.attemptedThisDown=false; incapacitated path: if aftermath.active and GetGameTimer() > aftermath.until_ then endAftermath() end.

13. [low/med][LIKELY] client.lua:4716-4728, 4698/4713 — WASTED error/stalled fade leaves game slowed and can block qbx_medical (never fires fenix-police:client:wastedScreenFadedOut which qbx_medical waits on); fade waits unbounded.
   Fix: in `if not ok`: SetTimeScale(1.0); StopScreenEffect('DeathFailOut'); RenderScriptCams(false,false,0,true,true); TriggerEvent('fenix-police:client:wastedScreenFadedOut'); DoScreenFadeIn(500). Bound fade waits ~3s. Skip WASTED while isBeingArrested.

14. [low][CONFIRMED] client.lua:5484-5489 — wanted status sent every second → global cleanup every 2s (see server.md #9).
   Fix: if lastReportedWantedState ~= isWantedNow or GetGameTimer()-lastHeartbeat > 15000 then TriggerServerEvent(...); update both end.

15. [low][CONFIRMED] client.lua:6097-6156 (+ client/investigate.lua:75-118) — patrol→investigation promotion races itself and leaks the driver: single-slot ticket wait; two incidents within 5s both pass unitCount() before units[] written; second ticket dropped; on failure caller deletes passengers + vehicle but not the networked mission-entity driver; passengerNetIDs[i] misaligned when a passenger fails networkizeEntity.
   Fix: serialize: while awaitingInvestigationPromotionTicket do Wait(50) end at entry; return {[netID]=ped} map (update caller in investigate.lua accordingly — that file belongs to the incident group, so if the signature changes, keep backward compatible or note it); failure path deletes driver.

16. [low][CONFIRMED] 3391 and 4949 — pressing H during ticket wrap-up starts a new stop and orphans the old unit (command guards isBeingArrested/isBeingTicketed but not ticketWrapUp; beginPullOver sets ticketUnit=nil; wrap-up reads stopUnit=ticketUnit only after its 12s wait).
   Fix: add `or ticketWrapUp` to guard; capture stopUnit at start of triggerTicket thread.

17. [low][CONFIRMED] 5014/5039 and 4811-4834 — units halted for a stop sit idle after cancel: drivers get ClearPedTasks + BringVehicleToHalt but officerTasks marker stays 'VehicleChase'; handleChaseBehavior (2071) only re-tasks on marker change.
   Fix: in releaseTicketUnit and at halt call sites set officerTasks[driverNetID] = nil.

18. [low][CONFIRMED] 4883/4901 (+ server.lua:1137) — fine charged before citation written; leaving vehicle mid-citation keeps money, wanted, hazards.
   Fix: send issueTicket after the writing loop. (Server checks → server group.)

19. [low][LIKELY] 5081 and 5151 — officer walking to window uses TaskGoStraightToCoord (ignores navmesh) → wedges against car; after 90s stop ends with cancelPullOver() silently; pursuit resumes against a complying driver.
   Fix: TaskFollowNavMeshToCoord(officer, x, y, z, 1.0, 20000, 0.5, 0, heading); re-issue if no progress; pass a reason message on timeout (and on timeout, prefer completing as a "warning, you're free to go" rather than resuming the pursuit).

20. [low][LIKELY] 4599 — qbx_arrest:server:reportArrest only sent if um_livingworld started, comment says it belongs to qbx_arrest. Fix: GetResourceState('qbx_arrest') == 'started'. (Check comments around it for intent first.)

21. [low][CONFIRMED] 6047-6051 — unit registry reports a random role (pairs order). Fix: report driver's task: d=GetPedInVehicleSeat(data.vehicle,-1); role = d~=0 and data.officerTasks[PedToNet(d)] or nil (check how data.vehicle is stored).

Improvements (not bugs): paired cuffing anim mp_arrest_paired (crook_p2_back_left / cop_p2_back_left), holster arresting officer (WEAPON_UNARMED), open rear door; show Config.ArrestSystem.bustedSubtitle (defined, never drawn) + charge; "suspect in custody" radio; traffic stop fend-off position for backup; CPR anim mini@cpr@char_a@cpr_str and kneel offset; call own EMS module when player downed; dismissUnit drive-away instead of in-view despawn; per-unit pcall around handleChaseBehavior in main loop so one bad unit can't abort heli/air loops; felony-stop path (driver ordered out at gunpoint) above ticket limit.
