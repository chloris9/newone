-- The match after training: a simulated 90 minutes told by the commentator, with 3-5 moments the
-- player plays himself in 3D. Everything is decided here; the client shows it and sends input.
--
-- Flow (MatchRequest: client -> server, MatchUpdate: server -> client):
--   CareerService "START_MATCH" -> MatchService.start: builds the timeline, returns the header.
--   "NEXT"   -> MatchUpdate { events, state } for the next slot of the timeline, or
--               { events, state, moment } when it is the player's moment, or { events, result } at
--               full time. What happens in a slot is rolled when it is reached, so the player's
--               effort and focus (below) change the rest of the match.
--   "EFFORT", 1|2|3 / "FOCUS", "ATTACK"|"DEFENSE" -> tactics. Stamina drains every match minute in
--               proportion to the effort; more effort = more moments and more time in them, low
--               stamina = less accurate and less time before the tackle.
--   moment   -> a MOMENT episode (MomentPhysics layout) inside the MatchUpdate. The client plays the
--               intro, then sends "READY": the decision clock starts and the presser tackles at
--               layout.tackleTime unless SubmitEpisodeInput (episodeId, a, b, power, clientTime,
--               action) arrives first: action SHOT (aimX, aimY, power), PASS or CROSS (dirX, dirZ,
--               power). Results come back as EpisodeResult.
--   "AUTO"   -> after your good pass or cross: the teammate's shot (a header after a cross),
--               simulated here and sent as an episode that already carries its result
--               (episode.auto). A goal counts as your assist.
-- The result is saved once, by CareerService.onMatchFinished, when full time is sent.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShotConfig = require(Shared:WaitForChild("ShotConfig"))
local PassConfig = require(Shared:WaitForChild("PassConfig"))
local PassPhysics = require(Shared:WaitForChild("PassPhysics"))
local CareerConfig = require(Shared:WaitForChild("CareerConfig"))
local MomentPhysics = require(Shared:WaitForChild("MomentPhysics"))
local EpisodeService = require(script.Parent.EpisodeService)
local ShotResolver = require(script.Parent.ShotResolver)

local Moment = MomentPhysics.Config

-- Timeline: SLOTS minutes get an event each (~1-2 commentary lines). With the client's line time
-- and 3-5 moments this makes a match of about 1.5-2 minutes.
local SLOTS = 17
local MOMENTS_MIN, MOMENTS_MAX = 3, 5
local MOMENT_CHANCE = 0.21 -- per slot, before effort / focus / stamina
local MIN_REMOTE_INTERVAL = 0.2
local MIN_TACTIC_INTERVAL = 0.15
local FIRST_EPISODE_ID = 100000 -- kept apart from training episode ids
local TEAMMATE_NUMBERS = { 7, 28 } -- MomentPhysics teammates 1 and 2
local PASSER_NUMBER = 28 -- RECEIVE moments: teammate 2 plays the ball to you

-- Stamina (0-100) lost per match minute, by effort: proportional to the effort.
local STAMINA_PER_MINUTE = 0.36
local HALFTIME_RECOVERY = 12
local EFFORT_MOMENTS = { 0.75, 1, 1.3 }
local FOCUS_MOMENTS = { ATTACK = 1.15, DEFENSE = 0.8 }

-- Filler lines between chances, by situation (keys in ShotClient/Commentary).
local FILLER = { "BUILDUP_US", "BUILDUP_THEM", "MIDFIELD", "FOUL_US", "FOUL_THEM", "CORNER_US", "CORNER_THEM", "OFFSIDE_US", "OFFSIDE_THEM", "CROWD", "KEEPER_US", "YELLOW_THEM", "YELLOW_US", "SUB_THEM" }
local FILLER_ATTACK = { "ME_RUN", "ME_CALL", "TEAM_PRESS" }
local FILLER_DEFENSE = { "ME_TRACK", "TEAM_DEEP" }

type Event = { minute: number, key: string, number: number? }
type Match = {
	career: any,
	home: CareerConfig.Club,
	away: CareerConfig.Club,
	rng: Random,
	slots: { number },
	cursor: number,
	minute: number,
	halftimeDone: boolean,
	homeGoals: number,
	awayGoals: number,
	momentIndex: number,
	lastMomentSlot: number,
	usedFiller: { [string]: boolean },
	effort: number,
	focus: string,
	stamina: number,
	tiredSaid: number,
	active: any?, -- moment episode in play
	auto: any?, -- good pass waiting for the teammate's shot
	nextEpisodeId: number,
	lastRemoteAt: number,
	lastTacticAt: number,
	stats: { goals: number, assists: number, shots: number, passes: number, goodPasses: number, tackles: number, lost: number },
	finished: boolean,
}

local MatchService = {}

local matches: { [Player]: Match } = {}
local remotes
local hooks = nil :: { onMatchFinished: (Player, any) -> any }?

local function keeperSkill(match: Match): number
	return math.clamp(match.away.ovr - 8, 30, 80)
end

local function edge(match: Match): number
	return (match.away.ovr - match.home.ovr) * 0.02
end

-- Shooting / passing for the player's own moment: his rating, worn down by low stamina.
local function freshness(match: Match): number
	return 0.75 + 0.25 * match.stamina / 100
end

local function playerSkill(match: Match, base: number): number
	local ovr = if typeof(match.career.ovr) == "number" then match.career.ovr else base
	return math.clamp(math.max(base, ovr) * freshness(match), 20, 90)
end

local function buildSlots(rng: Random): { number }
	local slots = {}
	for i = 1, SLOTS do
		-- One slot per slice of the 90 minutes, never on the whistles.
		local from = 2 + (i - 1) * 87 / SLOTS
		local minute = math.floor(from + rng:NextNumber() * (87 / SLOTS - 1))
		if minute == 45 then
			minute = 44
		end
		slots[i] = math.clamp(minute, 1, 89)
	end
	table.sort(slots)
	return slots
end

local function passesRateLimit(match: Match): boolean
	local now = os.clock()
	if now - match.lastRemoteAt < MIN_REMOTE_INTERVAL then
		return false
	end
	match.lastRemoteAt = now
	return true
end

local function score(match: Match)
	return { home = match.homeGoals, away = match.awayGoals }
end

local function state(match: Match)
	return { stamina = math.floor(match.stamina * 10 + 0.5) / 10, effort = match.effort, focus = match.focus, minute = match.minute }
end

local function summary(match: Match)
	local s = match.stats
	local outcome = if match.homeGoals > match.awayGoals then "WIN" elseif match.homeGoals == match.awayGoals then "DRAW" else "LOSS"
	local rating = 6 + s.goals * 1.1 + s.assists * 0.7 + s.goodPasses * 0.15 + s.tackles * 0.15
		- (s.shots - s.goals) * 0.1 - (s.passes - s.goodPasses) * 0.15 - s.lost * 0.15
	return {
		outcome = outcome,
		home = match.homeGoals,
		away = match.awayGoals,
		goals = s.goals,
		assists = s.assists,
		shots = s.shots,
		passes = s.passes,
		goodPasses = s.goodPasses,
		rating = math.floor(math.clamp(rating, 4, 10) * 10 + 0.5) / 10,
		xp = 20 + s.goals * 15 + s.assists * 10 + (if outcome == "WIN" then 20 elseif outcome == "DRAW" then 10 else 0),
	}
end

local function drainTo(match: Match, minute: number)
	local minutes = math.max(0, minute - match.minute)
	match.stamina = math.clamp(match.stamina - minutes * STAMINA_PER_MINUTE * match.effort, 0, 100)
	match.minute = math.max(match.minute, minute)
end

local function newEpisode(match: Match, kind: string)
	local episode = {
		id = match.nextEpisodeId,
		kind = kind,
		mode = "MATCH",
		seed = match.rng:NextInteger(1, 2 ^ 31 - 1),
		startedAt = os.clock(),
		match = { keeperSkill = keeperSkill(match) },
	}
	match.nextEpisodeId += 1
	return episode
end

local function episodePayload(episode, stage: string)
	return {
		episodeId = episode.id,
		kind = episode.kind,
		mode = episode.mode,
		layout = episode.layout,
		spot = episode.match.spot,
		match = true,
		-- Fields the training HUD code reads; its training panels are hidden in a match.
		stage = stage,
		goals = 0,
		shots = 0,
		bonusGoals = 0,
		taskGoals = 1,
		history = {},
	}
end

-- The player's moment: a situation outside the box, harder later in the match and against better
-- clubs, with more time for a fresh player who works hard.
local function newMoment(match: Match)
	local rng = match.rng
	local episode = newEpisode(match, "MOMENT")
	local difficulty = match.momentIndex / MOMENTS_MAX + (match.away.ovr - 60) / 60
	local defenders = if rng:NextNumber() < 0.35 + difficulty * 0.4 then 3 else 2
	local timeFactor = (0.8 + 0.1 * match.effort) * freshness(match)
	episode.layout = MomentPhysics.layout(Random.new(episode.seed), {
		receive = rng:NextNumber() < 0.5,
		defenders = defenders,
		timeFactor = timeFactor,
	})
	episode.readyAt = nil :: number?
	return episode
end

local tackle -- defined below

-- What happens in one slot of the timeline, rolled now so the current tactics count.
local function rollSlot(match: Match, slotIndex: number, minute: number, sent: { any }): any?
	local rng = match.rng
	local remaining = SLOTS - slotIndex
	local needed = MOMENTS_MIN - match.momentIndex
	local spaced = slotIndex - match.lastMomentSlot >= 2
	local chance = MOMENT_CHANCE * EFFORT_MOMENTS[match.effort] * (FOCUS_MOMENTS[match.focus] or 1) * (if match.stamina < 25 then 0.7 else 1)
	local isMoment = match.momentIndex < MOMENTS_MAX
		and spaced
		and slotIndex > 1
		and (needed > 0 and remaining < needed * 2 or rng:NextNumber() < chance)
	local function line(key: string, number: number?)
		table.insert(sent, { minute = minute, key = key, number = number, score = score(match) })
	end

	if isMoment then
		match.momentIndex += 1
		match.lastMomentSlot = slotIndex
		return newMoment(match)
	end

	local e = edge(match)
	local attack = match.focus == "ATTACK"
	local oppChance = (if attack then 0.27 else 0.15) + math.max(0, e) * 0.5
	local teamChance = (if attack then 0.2 else 0.13) - math.max(0, e) * 0.3
	local roll = rng:NextNumber()
	if roll < oppChance then
		local goal = math.clamp(0.27 + e + (if attack then 0.06 else -0.1) - (if attack then 0 else (match.effort - 1) * 0.04), 0.08, 0.5)
		local r = rng:NextNumber()
		line("OPP_ATTACK")
		if r < goal then
			match.awayGoals += 1
			line("OPP_GOAL")
		else
			line(if r < goal + 0.45 then "OPP_SAVE" else "OPP_MISS")
		end
	elseif roll < oppChance + teamChance then
		local number = TEAMMATE_NUMBERS[rng:NextInteger(1, #TEAMMATE_NUMBERS)]
		line("TEAM_ATTACK", number)
		if rng:NextNumber() < math.clamp(0.22 - e, 0.1, 0.35) then
			match.homeGoals += 1
			line("TEAM_GOAL", number)
		else
			line("TEAM_MISS", number)
		end
	else
		-- Your own work off the ball, then the general play.
		if match.stamina < 20 and match.tiredSaid < 2 then
			match.tiredSaid = 2
			line("ME_EXHAUSTED")
		elseif match.stamina < 45 and match.tiredSaid < 1 then
			match.tiredSaid = 1
			line("ME_TIRED")
		elseif match.focus == "DEFENSE" and rng:NextNumber() < 0.25 + 0.15 * match.effort then
			match.stats.tackles += 1
			line(if rng:NextNumber() < 0.5 then "ME_TACKLE" else FILLER_DEFENSE[rng:NextInteger(1, #FILLER_DEFENSE)])
		elseif attack and rng:NextNumber() < 0.3 then
			line(FILLER_ATTACK[rng:NextInteger(1, #FILLER_ATTACK)], TEAMMATE_NUMBERS[rng:NextInteger(1, #TEAMMATE_NUMBERS)])
		else
			-- Not the same filler twice in a match if it can be helped.
			local key = FILLER[rng:NextInteger(1, #FILLER)]
			for _ = 1, 6 do
				if not match.usedFiller[key] then
					break
				end
				key = FILLER[rng:NextInteger(1, #FILLER)]
			end
			match.usedFiller[key] = true
			line(key, TEAMMATE_NUMBERS[rng:NextInteger(1, #TEAMMATE_NUMBERS)])
		end
	end
	return nil
end

-- Sends the next slot of the timeline (with any whistle before it), or full time with the result.
local function advance(player: Player, match: Match)
	if match.finished or match.active or match.auto then
		return
	end
	local sent = {}
	if match.cursor == 0 then
		match.cursor = 1
		table.insert(sent, { minute = 0, key = "KICKOFF", score = score(match) })
		remotes.MatchUpdate:FireClient(player, { events = sent, score = score(match), state = state(match) })
		return
	end
	local slotIndex = match.cursor
	local minute = match.slots[slotIndex]
	if minute and minute > 45 and not match.halftimeDone then
		match.halftimeDone = true
		drainTo(match, 45)
		match.stamina = math.min(100, match.stamina + HALFTIME_RECOVERY)
		table.insert(sent, { minute = 45, key = "HALFTIME", score = score(match) })
	end
	if minute then
		match.cursor += 1
		drainTo(match, minute)
		if minute >= 84 and not match.usedFiller.LATE then
			match.usedFiller.LATE = true
			table.insert(sent, { minute = minute, key = "LATE", score = score(match) })
		end
		local moment = rollSlot(match, slotIndex, minute, sent)
		if moment then
			match.active = moment
			local layout = moment.layout
			remotes.MatchUpdate:FireClient(player, {
				events = sent,
				score = score(match),
				state = state(match),
				moment = {
					kind = layout.kind,
					minute = minute,
					index = match.momentIndex,
					number = PASSER_NUMBER,
					episode = episodePayload(moment, "MOMENT"),
				},
			})
			return
		end
		remotes.MatchUpdate:FireClient(player, { events = sent, score = score(match), state = state(match) })
		return
	end

	drainTo(match, 90)
	table.insert(sent, { minute = 90, key = "FULLTIME", score = score(match) })
	match.finished = true
	local result = summary(match)
	local reward = hooks and hooks.onMatchFinished(player, result)
	print(string.format(
		"[MatchService] %s: full time %d:%d, goals %d, assists %d, rating %.1f",
		player.Name, match.homeGoals, match.awayGoals, result.goals, result.assists, result.rating
	))
	remotes.MatchUpdate:FireClient(player, { events = sent, score = score(match), state = state(match), result = result, career = reward })
	matches[player] = nil
end

-- After your good pass or cross: the teammate shoots (heads a cross). Aim and power are his own.
local function autoShot(player: Player, match: Match)
	local auto = match.auto
	if not auto then
		return
	end
	match.auto = nil
	local rng = match.rng
	local episode = newEpisode(match, "SHOT")
	episode.mode = "AUTO"
	local side = if rng:NextNumber() < 0.5 then -1 else 1
	local input
	if auto.header then
		input = { aimX = side * (0.25 + rng:NextNumber() * 0.65), aimY = rng:NextNumber() * 0.45, power = 0.2 + rng:NextNumber() * 0.3 }
	else
		input = { aimX = side * (0.35 + rng:NextNumber() * 0.5), aimY = 0.15 + rng:NextNumber() * 0.6, power = 0.55 + rng:NextNumber() * 0.3 }
	end
	local stats = { shooting = math.clamp(match.home.ovr - (if auto.header then 18 else 12), 25, 80), keeperSkill = keeperSkill(match) }
	local result = ShotResolver.resolve(input, stats, Random.new(episode.seed), { start = auto.spot })
	local sim = result.sim
	local goal = result.outcome == "GOAL"
	if goal then
		match.homeGoals += 1
		match.stats.assists += 1
	end
	local payload = episodePayload(episode, "SHOT")
	payload.spot = auto.spot
	payload.receiver = auto.receiver
	payload.header = auto.header
	-- Same fields as an EpisodeResult for a shot: the client replays this path.
	payload.auto = {
		episodeId = episode.id,
		kind = "SHOT",
		mode = "AUTO",
		header = auto.header,
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
		outcome = result.outcome,
		detail = result.detail,
		speedKmh = result.speedKmh,
		number = TEAMMATE_NUMBERS[auto.receiver] or TEAMMATE_NUMBERS[1],
		score = score(match),
	}
	remotes.EpisodeStarted:FireClient(player, payload)
end

local function sendResult(player: Player, match: Match, active, payload)
	payload.episodeId = active.id
	payload.kind = "MOMENT"
	payload.mode = "MATCH"
	payload.match = true
	payload.score = score(match)
	payload.state = state(match)
	remotes.EpisodeResult:FireClient(player, payload)
end

-- Too late: the presser gets there first.
function tackle(player: Player, match: Match, active)
	if match.active ~= active then
		return
	end
	match.active = nil
	match.stats.lost += 1
	sendResult(player, match, active, { action = "TACKLE", outcome = "TACKLED", detail = "TACKLED", tackler = active.layout.tackler })
end

-- The intro is over on the client: the decision clock starts, and the tackle is scheduled.
local function onReady(player: Player, match: Match)
	local active = match.active
	if not active or active.readyAt then
		return
	end
	active.readyAt = os.clock()
	task.delay(active.layout.tackleTime + Moment.TackleGrace, function()
		if matches[player] == match then
			tackle(player, match, active)
		end
	end)
end

local function setEffort(match: Match, value: any)
	if typeof(value) == "number" and (value == 1 or value == 2 or value == 3) then
		match.effort = value
	end
end

local function setFocus(match: Match, value: any)
	if value == "ATTACK" or value == "DEFENSE" then
		match.focus = value
	end
end

local function onRequest(player: Player, action: any, value: any)
	local match = matches[player]
	if not match or typeof(action) ~= "string" then
		return
	end
	if action == "EFFORT" or action == "FOCUS" then
		-- Own limit, so a tap on a tactic button never swallows the next NEXT.
		local now = os.clock()
		if now - match.lastTacticAt < MIN_TACTIC_INTERVAL then
			return
		end
		match.lastTacticAt = now
		if action == "EFFORT" then
			setEffort(match, value)
		else
			setFocus(match, value)
		end
		return
	end
	if action == "READY" then
		onReady(player, match) -- once per moment, so no rate limit needed
		return
	end
	if not passesRateLimit(match) then
		return
	end
	if action == "NEXT" then
		advance(player, match)
	elseif action == "AUTO" then
		autoShot(player, match)
	end
end

local function reject(player: Player, episodeId: any, reason: string)
	warn(string.format("[MatchService] %s: rejected input for episode %s (%s)", player.Name, tostring(episodeId), reason))
	remotes.EpisodeResult:FireClient(player, { episodeId = if typeof(episodeId) == "number" then episodeId else nil, rejected = true, reason = reason, match = true })
end

local function resolveMomentShot(match: Match, active, aimX: number, aimY: number, power: number)
	local layout = active.layout
	local input = { aimX = math.clamp(aimX, -1, 1), aimY = math.clamp(aimY, 0, 1), power = math.clamp(power, 0, 1) }
	local stats = { shooting = playerSkill(match, ShotConfig.DefaultShooting), keeperSkill = keeperSkill(match) }
	local result = ShotResolver.resolve(input, stats, Random.new(active.seed), {
		start = MomentPhysics.shotSpot(layout),
		scatterScale = MomentPhysics.shotScatterScale(layout),
	})
	local sim = result.sim
	return result.outcome, result.detail, result.speedKmh, {
		spot = MomentPhysics.shotSpot(layout),
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
end

local function gaussian(rng: Random): number
	local u1 = math.max(rng:NextNumber(), 1e-9)
	local u2 = rng:NextNumber()
	return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
end

local function resolveMomentPass(match: Match, active, dirX: number, dirZ: number, power: number, releaseTime: number, high: boolean)
	local rng = Random.new(active.seed)
	local accuracy = PassConfig.Accuracy
	local skill = playerSkill(match, PassConfig.DefaultPassing) / 100
	local cap = accuracy.MaxSigmas
	local angleSigma = accuracy.AngleAtZeroSkill + (accuracy.AngleAtMaxSkill - accuracy.AngleAtZeroSkill) * skill
	local distanceSigma = accuracy.DistanceAtZeroSkill + (accuracy.DistanceAtMaxSkill - accuracy.DistanceAtZeroSkill) * skill
	if high then
		angleSigma *= Moment.CrossAngleScale
		distanceSigma *= Moment.CrossDistanceScale
	end
	local angle = math.rad(math.clamp(gaussian(rng), -cap, cap) * angleSigma)
	local stretch = 1 + math.clamp(gaussian(rng), -cap, cap) * distanceSigma
	local reaction = PassConfig.Defender.Reaction + (rng:NextNumber() * 2 - 1) * PassConfig.Defender.ReactionJitter

	local dir = Vector3.new(dirX, 0, dirZ).Unit
	local c, s = math.cos(angle), math.sin(angle)
	dir = Vector3.new(dir.X * c - dir.Z * s, 0, dir.X * s + dir.Z * c)
	local distance
	if high then
		distance = math.clamp(power * Moment.CrossMaxRange, Moment.CrossMinRange, Moment.CrossMaxRange) * stretch
	else
		distance = PassPhysics.distanceForPower(power) * stretch
	end
	local sim = MomentPhysics.simulatePass(active.layout, dir, distance, releaseTime, reaction, high)
	return sim
end

local function onSubmit(player: Player, episodeId: any, a: any, b: any, power: any, clientTime: any, action: any)
	local match = matches[player]
	if not match then
		return
	end
	local active = match.active
	if not active or episodeId ~= active.id then
		reject(player, episodeId, "unknown or already finished episode")
		return
	end
	if not passesRateLimit(match) then
		reject(player, episodeId, "too many requests")
		return
	end
	local inRange = EpisodeService.isNumberInRange
	local shot = action == "SHOT"
	if not (shot or action == "PASS" or action == "CROSS") then
		reject(player, episodeId, "unknown action")
		return
	end
	if not (inRange(a, -1, 1) and inRange(b, if shot then 0 else -1, 1) and inRange(power, 0, 1)) then
		reject(player, episodeId, "invalid input values")
		return
	end
	if not active.readyAt then
		reject(player, episodeId, "input before the moment started")
		return
	end
	local elapsed = os.clock() - active.readyAt
	if elapsed < 0.15 then
		reject(player, episodeId, "input too early")
		return
	end
	-- When it was played: the client's clock, never ahead of ours or more than MaxLag behind.
	local releaseTime = elapsed
	if typeof(clientTime) == "number" and clientTime == clientTime then
		releaseTime = math.clamp(clientTime, math.max(0, elapsed - Moment.MaxLag), elapsed)
	end
	if releaseTime > active.layout.tackleTime then
		tackle(player, match, active)
		return
	end

	-- Consume the episode once it has a result, so it can never produce a second one.
	match.active = nil
	local stats = match.stats
	local payload
	if shot then
		local outcome, detail, speedKmh, shotPayload = resolveMomentShot(match, active, a, b, power)
		payload = shotPayload
		payload.action = "SHOT"
		payload.outcome, payload.detail, payload.speedKmh = outcome, detail, speedKmh
		stats.shots += 1
		if outcome == "GOAL" then
			stats.goals += 1
			match.homeGoals += 1
		end
	else
		if Vector3.new(a, 0, b).Magnitude < 0.1 then
			match.active = active
			reject(player, episodeId, "invalid input values")
			return
		end
		local high = action == "CROSS"
		local sim = resolveMomentPass(match, active, a, b, power, releaseTime, high)
		stats.passes += 1
		payload = {
			action = action,
			outcome = sim.outcome,
			detail = sim.detail,
			speedKmh = math.floor(sim.speed + 0.5),
			releaseTime = releaseTime,
			sampleStep = PassConfig.SampleStep,
			ball = sim.ball,
			defenders = sim.defenders,
			mates = sim.mates,
			receiver = sim.receiver,
			interceptor = sim.interceptor,
			header = sim.header,
			eventTime = sim.eventTime,
			endTime = sim.endTime,
			number = sim.receiver and TEAMMATE_NUMBERS[sim.receiver],
		}
		if sim.detail == "GOOD" and sim.receiver and sim.meet then
			stats.goodPasses += 1
			local spot
			if sim.header then
				spot = Vector3.new(sim.meet.X, Moment.HeaderHeight, sim.meet.Z)
			else
				-- The receiver takes a touch towards goal and shoots.
				local toGoal = Vector3.new(-sim.meet.X, 0, -sim.meet.Z).Unit
				local ground = sim.meet + toGoal * PassConfig.Teammate.Reach * 0.7
				spot = Vector3.new(ground.X, ShotConfig.Ball.Radius, ground.Z)
			end
			match.auto = { spot = spot, receiver = sim.receiver, header = sim.header }
			payload.followUp = true
		end
	end
	sendResult(player, match, active, payload)
end

-- CareerService "START_MATCH": a new match against the career's next opponent.
function MatchService.start(player: Player, career: any)
	local home = CareerConfig.club(career.clubId)
	if not home then
		return nil
	end
	local away = CareerConfig.firstOpponent(home)
	local rng = Random.new()
	matches[player] = {
		career = career,
		home = home,
		away = away,
		rng = rng,
		slots = buildSlots(rng),
		cursor = 0,
		minute = 0,
		halftimeDone = false,
		homeGoals = 0,
		awayGoals = 0,
		momentIndex = 0,
		lastMomentSlot = -10,
		usedFiller = {},
		effort = 2,
		focus = "ATTACK",
		stamina = 100,
		tiredSaid = 0,
		nextEpisodeId = FIRST_EPISODE_ID,
		lastRemoteAt = -math.huge,
		lastTacticAt = -math.huge,
		stats = { goals = 0, assists = 0, shots = 0, passes = 0, goodPasses = 0, tackles = 0, lost = 0 },
		finished = false,
	}
	print(string.format("[MatchService] %s: %s - %s", player.Name, home.id, away.id))
	return { homeId = home.id, awayId = away.id, moments = MOMENTS_MAX, effort = 2, focus = "ATTACK", stamina = 100 }
end

-- Back to the menus or into training: an unfinished match is dropped without a result.
function MatchService.stop(player: Player)
	matches[player] = nil
end

-- matchHooks.onMatchFinished(player, summary) saves the result and returns the updated career.
function MatchService.init(remoteEvents, matchHooks)
	if remotes then
		warn("[MatchService] init called twice; ignoring")
		return
	end
	remotes = remoteEvents
	hooks = matchHooks
	remotes.MatchRequest.OnServerEvent:Connect(onRequest)
	remotes.SubmitEpisodeInput.OnServerEvent:Connect(onSubmit)
	Players.PlayerRemoving:Connect(function(player)
		matches[player] = nil
	end)
end

-- Exposed for offline balance checks (tools/sim).
MatchService._buildSlots = buildSlots
MatchService._rollSlot = rollSlot

return MatchService
