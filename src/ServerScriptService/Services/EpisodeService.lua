-- Owns interactive episodes: hands them out, validates client input and sends back results.
-- The client only ever sends its input; it never reports an outcome.
--
-- Training flow, decided here so the client can't skip it:
--   stage SHOT  TUTORIAL (one guided shot that always scores) -> TASK (score Training.TaskGoals)
--   stage PASS  TUTORIAL (one guided pass that always arrives) -> TASK (PassConfig.Training.TaskPasses good passes)
--   After a TASK the phase is DONE and the menu asks for "RETRY" (task again) or "NEXT" (next stage).
--   "NEXT" after the PASS task ends the training: no more episodes, the client goes back to the menu.
--   A good pass is followed by a SHOT episode (mode FOLLOWUP) from where the receiver took the ball;
--   the pass already counted, the shot only adds to `bonusGoals`. The pass's status (TUTORIAL_DONE,
--   CONTINUE, COMPLETED) is reported with the shot's result.
-- Misses never reset task progress. Only players put into training by CareerService (beginTraining)
-- get episodes; each completed task is reported back through hooks.onStageCompleted.
--
-- Input per episode kind (SubmitEpisodeInput):
--   SHOT  (episodeId, aimX -1..1, aimY 0..1, power 0..1)
--   PASS  (episodeId, dirX -1..1, dirZ -1..1, power 0..1, clientTime) - clientTime: seconds since
--         the client showed the episode; sets where the patrolling defender was, within MaxLag.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShotConfig = require(Shared:WaitForChild("ShotConfig"))
local PassConfig = require(Shared:WaitForChild("PassConfig"))
local PassPhysics = require(Shared:WaitForChild("PassPhysics"))
local ShotResolver = require(script.Parent.ShotResolver)
local PassResolver = require(script.Parent.PassResolver)

local Training = ShotConfig.Training
local PassTraining = PassConfig.Training
local MAX_LAG = 0.6 -- seconds a pass's clientTime may trail the server clock
local STAGES = { SHOT = true, PASS = true }

type Episode = {
	id: number,
	kind: string, -- SHOT | PASS
	mode: string, -- TUTORIAL | TASK | FOLLOWUP
	seed: number,
	startedAt: number,
	layout: PassPhysics.Layout?,
	followUp: FollowUp?,
}
type FollowUp = {
	spot: Vector3, -- ball position for the shot
	receiver: number, -- teammate index
	phaseMode: string, -- the pass's mode (TUTORIAL | TASK)
	passStatus: string, -- the pass's training status
}
type PlayerState = {
	nextEpisodeId: number,
	active: Episode?,
	lastRemoteAt: number,
	stage: string, -- SHOT | PASS
	phase: string, -- TUTORIAL | TASK | DONE
	shots: number, -- attempts in the current task
	goals: number, -- goals / good passes
	history: { string }, -- outcome of each attempt, most recent last
	bonusGoals: number, -- pass stage: goals scored after good passes in this task attempt
	followUp: FollowUp?, -- a good pass waiting for its shot
}

local EpisodeService = {}

local states: { [Player]: PlayerState } = {}
local nextIds: { [Player]: number } = {} -- episode ids keep counting across training sessions
local seedSource = Random.new()
local remotes
local hooks = nil :: { onStageCompleted: (Player, string) -> () }?

local function resetCounters(state: PlayerState)
	state.shots, state.goals, state.history, state.bonusGoals = 0, 0, {}, 0
end

local function passesRateLimit(state: PlayerState): boolean
	local now = os.clock()
	if now - state.lastRemoteAt < ShotConfig.Episode.MinRemoteInterval then
		return false
	end
	state.lastRemoteAt = now
	return true
end

-- Rejects non-numbers, NaN, infinities and out-of-range values.
local function isNumberInRange(value: any, min: number, max: number): boolean
	if typeof(value) ~= "number" or value ~= value then
		return false
	end
	local tolerance = ShotConfig.Episode.InputTolerance
	return value >= min - tolerance and value <= max + tolerance
end

local function taskGoal(stage: string): number
	return if stage == "PASS" then PassTraining.TaskPasses else Training.TaskGoals
end

local function progress(state: PlayerState)
	return {
		stage = state.stage,
		goals = state.goals,
		shots = state.shots,
		bonusGoals = state.bonusGoals,
		taskGoals = taskGoal(state.stage),
		history = table.clone(state.history),
	}
end

-- Guided aim for a shot from `spot`: the far top corner, as seen from that side of the pitch.
local function guidedAim(spot: Vector3?): (number, number)
	local x = Training.TutorialAim.X
	if spot and spot.X > 0 then
		x = -x
	end
	return x, Training.TutorialAim.Y
end

local function shotHint(spot: Vector3?)
	local aimX, aimY = guidedAim(spot)
	return {
		aimX = aimX,
		aimY = aimY,
		ringRadius = Training.TutorialRingRadius,
		tapRadius = Training.TutorialTapRadius,
		powerMin = Training.GuidedPowerMin,
		powerMax = Training.GuidedPowerMax,
	}
end

local function passHint(layout: PassPhysics.Layout)
	local mate = layout.teammates[PassTraining.TutorialTarget]
	local distance = Vector3.new(mate.X - layout.origin.X, 0, mate.Z - layout.origin.Z).Magnitude
	return {
		start = layout.origin,
		target = mate,
		targetIndex = PassTraining.TutorialTarget,
		ringRadius = PassTraining.RingRadius,
		tapRadius = PassTraining.TapRadius,
		powerMin = PassPhysics.powerForDistance(distance - 6),
		powerMax = PassPhysics.powerForDistance(distance + 8),
	}
end

local function sendEpisode(player: Player, state: PlayerState, episode: Episode)
	local payload = progress(state)
	payload.episodeId = episode.id
	payload.kind = episode.kind
	payload.mode = episode.mode
	payload.layout = episode.layout
	if episode.followUp then
		payload.spot = episode.followUp.spot
		payload.receiver = episode.followUp.receiver
		payload.phaseMode = episode.followUp.phaseMode
	end
	if episode.mode == "TUTORIAL" then
		if episode.kind == "PASS" then
			payload.hint = passHint(episode.layout :: PassPhysics.Layout)
		else
			payload.hint = shotHint(nil)
		end
	elseif episode.followUp and episode.followUp.phaseMode == "TUTORIAL" then
		payload.hint = shotHint(episode.followUp.spot) -- first shot after the guided pass is guided too
	end
	remotes.EpisodeStarted:FireClient(player, payload)
end

-- choice: what the completion menu asked for ("RETRY" or "NEXT"); ignored in other phases.
local function startEpisode(player: Player, state: PlayerState, choice: string?)
	local followUp = state.followUp
	if followUp then
		-- The shot after a good pass comes first, even if that pass completed the task.
		state.followUp = nil
		local episode = {
			id = state.nextEpisodeId,
			kind = "SHOT",
			mode = "FOLLOWUP",
			seed = seedSource:NextInteger(1, 2 ^ 31 - 1),
			startedAt = os.clock(),
			followUp = followUp,
		}
		state.nextEpisodeId += 1
		state.active = episode
		print(string.format(
			"[EpisodeService] %s: episode #%d started (SHOT FOLLOWUP from (%.1f, %.1f), seed %d)",
			player.Name, episode.id, followUp.spot.X, followUp.spot.Z, episode.seed
		))
		sendEpisode(player, state, episode)
		return
	end
	if state.phase == "DONE" then
		if choice == "NEXT" then
			if state.stage ~= "SHOT" then
				return -- the pass task was the last one: training is over
			end
			state.stage = "PASS"
			state.phase = "TUTORIAL"
		else
			state.phase = "TASK"
		end
		resetCounters(state)
	end
	local seed = seedSource:NextInteger(1, 2 ^ 31 - 1)
	local kind = if state.stage == "PASS" then "PASS" else "SHOT"
	local mode = state.phase
	local layout
	if kind == "PASS" then
		-- The situation is picked from the seed too, so (seed, input) reproduces the whole pass.
		local rng = Random.new(seed)
		local index = if mode == "TUTORIAL" then PassTraining.TutorialLayout else rng:NextInteger(2, #PassConfig.Layouts)
		layout = PassPhysics.layout(index, rng:NextNumber() * 2)
	end
	local episode = { id = state.nextEpisodeId, kind = kind, mode = mode, seed = seed, startedAt = os.clock(), layout = layout }
	state.nextEpisodeId += 1
	state.active = episode
	print(string.format(
		"[EpisodeService] %s: episode #%d started (%s %s%s, seed %d)",
		player.Name, episode.id, kind, mode, if layout then ", layout " .. layout.index else "", seed
	))
	sendEpisode(player, state, episode)
end

local function reject(player: Player, episodeId: any, reason: string)
	warn(string.format("[EpisodeService] %s: rejected input for episode %s (%s)", player.Name, tostring(episodeId), reason))
	remotes.EpisodeResult:FireClient(player, {
		episodeId = if typeof(episodeId) == "number" then episodeId else nil,
		rejected = true,
		reason = reason,
	})
end

local function onRequestEpisode(player: Player, choice: any)
	local state = states[player]
	if not state or not passesRateLimit(state) then
		return
	end

	local active = state.active
	if active and os.clock() - active.startedAt <= ShotConfig.Episode.Timeout then
		-- Client lost track of it (e.g. after a rejection): resend instead of issuing a new one.
		sendEpisode(player, state, active)
		return
	end
	startEpisode(player, state, if typeof(choice) == "string" then choice else nil)
end

-- Updates the training progress after an attempt and returns what happens next:
-- TUTORIAL_DONE | TUTORIAL_RETRY | CONTINUE | COMPLETED
local function advance(state: PlayerState, mode: string, success: boolean, outcome: string): string
	if mode == "TUTORIAL" then
		if not success then
			return "TUTORIAL_RETRY" -- should not happen: guided attempts always succeed
		end
		state.phase = "TASK"
		resetCounters(state)
		return "TUTORIAL_DONE"
	end

	state.shots += 1
	if success then
		state.goals += 1
	end
	table.insert(state.history, outcome)
	if state.goals >= taskGoal(state.stage) then
		state.phase = "DONE"
		return "COMPLETED"
	end
	return "CONTINUE"
end

local function resolveShot(active: Episode, aimX: number, aimY: number, power: number)
	local input = {
		aimX = math.clamp(aimX, -1, 1),
		aimY = math.clamp(aimY, 0, 1),
		power = math.clamp(power, 0, 1),
	}
	local stats = { shooting = ShotConfig.DefaultShooting, keeperSkill = Training.TaskKeeperSkill }
	local options
	local followUp = active.followUp
	local match = (active :: any).match -- MatchService: { keeperSkill, shooting?, spot? }
	if match then
		stats.keeperSkill = match.keeperSkill
		stats.shooting = match.shooting or stats.shooting
		options = { start = match.spot }
	elseif followUp then
		-- Training keeper; the first one (after the guided pass) is a sure goal like the guided shot.
		options = { start = followUp.spot, keeperDelay = Training.TaskKeeperDelay }
		if followUp.phaseMode == "TUTORIAL" then
			local guideX, guideY = guidedAim(followUp.spot)
			options.guided = { aimX = guideX, aimY = guideY }
		end
	elseif active.mode == "TUTORIAL" then
		local guideX, guideY = guidedAim(nil)
		options = { guided = { aimX = guideX, aimY = guideY } }
	else
		options = { keeperDelay = Training.TaskKeeperDelay }
	end
	local result = ShotResolver.resolve(input, stats, Random.new(active.seed), options)
	local used = result.input
	local sim = result.sim
	-- The client replays this exact path, so what it shows always matches the outcome.
	local payload = {
		path = sim.path,
		sampleStep = ShotConfig.Physics.SampleStep,
		events = sim.events,
		spin = result.spin,
		held = sim.held,
		decisiveTime = result.decisiveTime,
		keeperTime = sim.keeperTime,
		keeperTarget = result.keeperTarget,
		keeperReaction = result.keeperReaction,
		keeperDives = result.keeperDives,
		keeperKind = sim.keeperKind,
	}
	local summary = string.format("aim=(%.2f, %.2f) power=%.2f", used.aimX, used.aimY, used.power)
	return result.outcome == "GOAL", result.outcome, result.detail, result.speedKmh, payload, summary
end

local function resolvePass(active: Episode, dirX: number, dirZ: number, power: number, clientTime: any)
	if Vector3.new(dirX, 0, dirZ).Magnitude < 0.1 then
		return nil
	end
	-- Where the defender was: the client's clock, but never ahead of ours or more than MAX_LAG behind.
	local elapsed = os.clock() - active.startedAt
	local releaseTime = elapsed - 0.1
	if typeof(clientTime) == "number" and clientTime == clientTime then
		releaseTime = math.clamp(clientTime, math.max(0, elapsed - MAX_LAG), elapsed)
	end
	local input = { dirX = dirX, dirZ = dirZ, power = math.clamp(power, 0, 1) }
	local options = { releaseTime = releaseTime, guided = nil :: { target: number }? }
	if active.mode == "TUTORIAL" then
		options.guided = { target = PassTraining.TutorialTarget }
	end
	local result = PassResolver.resolve(input, active.layout :: PassPhysics.Layout, PassConfig.DefaultPassing, Random.new(active.seed), options)
	local sim = result.sim
	local payload = {
		sampleStep = PassConfig.SampleStep,
		releaseTime = releaseTime,
		ball = sim.ball,
		defender = sim.defender,
		receiver = sim.receiver,
		receiverTrack = sim.receiverTrack,
		eventTime = sim.eventTime,
		endTime = sim.endTime,
	}
	local used = result.input
	local summary = string.format("dir=(%.2f, %.2f) power=%.2f t=%.2f", used.dirX, used.dirZ, used.power, releaseTime)
	return result.outcome == "GOOD", result.outcome, result.detail, result.speedKmh, payload, summary
end

local function onSubmitEpisodeInput(player: Player, episodeId: any, a: any, b: any, power: any, clientTime: any)
	local state = states[player]
	if not state or not passesRateLimit(state) then
		return
	end

	local active = state.active
	if not active or episodeId ~= active.id then
		reject(player, episodeId, "unknown or already finished episode")
		return
	end
	local bMin = if active.kind == "PASS" then -1 else 0
	if not (isNumberInRange(a, -1, 1) and isNumberInRange(b, bMin, 1) and isNumberInRange(power, 0, 1)) then
		reject(player, episodeId, "invalid input values")
		return
	end

	local elapsed = os.clock() - active.startedAt
	if elapsed < ShotConfig.Episode.MinThinkTime then
		reject(player, episodeId, "input too early")
		return
	end
	if elapsed > ShotConfig.Episode.Timeout then
		state.active = nil
		reject(player, episodeId, "episode expired")
		return
	end

	local success, outcome, detail, speedKmh, payload, summary
	if active.kind == "PASS" then
		success, outcome, detail, speedKmh, payload, summary = resolvePass(active, math.clamp(a, -1, 1), math.clamp(b, -1, 1), power, clientTime)
		if success == nil then
			reject(player, episodeId, "invalid input values")
			return
		end
	else
		success, outcome, detail, speedKmh, payload, summary = resolveShot(active, a, b, power)
	end

	-- Consume the episode once it has a result, so it can never produce a second one.
	state.active = nil
	local status
	local followUp = active.followUp
	if followUp then
		status = followUp.passStatus -- the pass already counted
		if success and followUp.phaseMode == "TASK" then
			state.bonusGoals += 1
		end
	else
		status = advance(state, active.mode, success, outcome)
		if status == "COMPLETED" and hooks then
			hooks.onStageCompleted(player, state.stage)
		end
		if active.kind == "PASS" and success and payload.receiver and payload.receiverTrack then
			-- The receiver takes it towards goal and shoots next.
			local meet = payload.receiverTrack[#payload.receiverTrack]
			local toGoal = Vector3.new(-meet.X, 0, -meet.Z).Unit
			local ground = meet + toGoal * PassConfig.Teammate.Reach * 0.7
			state.followUp = {
				spot = Vector3.new(ground.X, ShotConfig.Ball.Radius, ground.Z),
				receiver = payload.receiver,
				phaseMode = active.mode,
				passStatus = status,
			}
			payload.followUp = true
		end
	end
	print(string.format(
		"[EpisodeService] %s: episode #%d %s %s %s -> %s/%s, %d km/h, %s (%d of %d)",
		player.Name, active.id, active.kind, active.mode, summary, outcome, detail, speedKmh,
		status, state.goals, state.shots
	))

	local info = progress(state)
	for key, value in info do
		payload[key] = value
	end
	payload.episodeId = active.id
	payload.kind = active.kind
	payload.mode = active.mode
	payload.status = status
	payload.outcome = outcome
	payload.detail = detail
	payload.speedKmh = speedKmh
	remotes.EpisodeResult:FireClient(player, payload)
end

-- Shared with MatchService, so match moments resolve exactly like training ones.
EpisodeService.resolveShot = resolveShot
EpisodeService.resolvePass = resolvePass
EpisodeService.isNumberInRange = isNumberInRange

-- Starts (or restarts) the training at `stage` (SHOT | PASS), from its guided attempt.
function EpisodeService.beginTraining(player: Player, stage: string)
	local old = states[player]
	if old then
		nextIds[player] = old.nextEpisodeId
	end
	states[player] = {
		nextEpisodeId = nextIds[player] or 1,
		active = nil,
		lastRemoteAt = -math.huge,
		stage = if STAGES[stage] then stage else "SHOT",
		phase = "TUTORIAL",
		shots = 0,
		goals = 0,
		history = {},
		bonusGoals = 0,
	}
end

-- Back to the menus: any open episode is dropped and further requests are ignored.
function EpisodeService.stopTraining(player: Player)
	local state = states[player]
	if state then
		nextIds[player] = state.nextEpisodeId
		states[player] = nil
	end
end

-- trainingHooks.onStageCompleted(player, stage) runs when a SHOT or PASS task is completed.
function EpisodeService.init(remoteEvents, trainingHooks)
	if remotes then
		warn("[EpisodeService] init called twice; ignoring")
		return
	end
	remotes = remoteEvents
	hooks = trainingHooks
	remotes.RequestEpisode.OnServerEvent:Connect(onRequestEpisode)
	remotes.SubmitEpisodeInput.OnServerEvent:Connect(onSubmitEpisodeInput)
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
		nextIds[player] = nil
	end)
end

return EpisodeService
