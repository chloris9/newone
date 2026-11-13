-- The match after training: a simulated 90 minutes told by the commentator, with 5-7 moments the
-- player plays himself. Everything is decided here; the client shows it and sends input.
--
-- Flow (MatchRequest: client -> server, MatchUpdate: server -> client):
--   CareerService "START_MATCH" -> MatchService.start: builds the timeline, returns the header.
--   "NEXT"   -> MatchUpdate { events, state } for the next slot of the timeline, or
--               { events, state, moment } when it is the player's moment (events are then the
--               chance's build-up lines), or { events, result } at full time. What happens in a
--               slot is rolled when it is reached, so effort and focus change the rest of the match.
--   "EFFORT", 1|2|3 / "FOCUS", "ATTACK"|"DEFENSE" -> tactics. Stamina drains every match minute in
--               proportion to the effort; more effort = more moments and more time in them, low
--               stamina = less accurate and less time before the tackle.
--   moment   -> a MOMENT episode (MomentPhysics layout). The client plays the step's intro, then
--               sends "READY", step: the decision clock starts and the presser tackles at
--               layout.tackleTime unless MomentInput arrives first:
--               (episodeId, step, dirX, dirZ, length, hitX, hitY, aimTime) = the arrow on the
--               ground and where the ball was struck. The result (EpisodeResult, kind MOMENT) is a
--               shot, or a pass that is lost, finished by a teammate near goal (result.finish), or
--               played back to you (result.continue = the next step's layout).
-- The result is saved once, by CareerService.onMatchFinished, when full time is sent.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShotConfig = require(Shared:WaitForChild("ShotConfig"))
local PassConfig = require(Shared:WaitForChild("PassConfig"))
local CareerConfig = require(Shared:WaitForChild("CareerConfig"))
local MomentPhysics = require(Shared:WaitForChild("MomentPhysics"))
local ShotResolver = require(script.Parent.ShotResolver)

local Moment = MomentPhysics.Config

-- Timeline: SLOTS minutes get an event each. A moment is 2-3 build-up lines, the play and 1-2
-- result lines; the rest are single lines. About 2-2.5 minutes a match.
local SLOTS = 15
local MOMENTS_MIN, MOMENTS_MAX = 5, 7
local MOMENT_CHANCE = 0.36 -- per slot, before effort / focus / stamina
local MIN_REMOTE_INTERVAL = 0.15
local MIN_TACTIC_INTERVAL = 0.15
local FIRST_EPISODE_ID = 100000 -- kept apart from training episode ids
local TEAMMATE_NUMBERS = { 7, 28 } -- MomentPhysics teammates 1 and 2

-- Stamina (0-100) lost per match minute, by effort: proportional to the effort.
local STAMINA_PER_MINUTE = 0.36
local HALFTIME_RECOVERY = 12
local EFFORT_MOMENTS = { 0.75, 1, 1.3 }
local FOCUS_MOMENTS = { ATTACK = 1.15, DEFENSE = 0.8 }

-- Filler lines between chances (keys in ShotClient/Commentary).
local FILLER = { "BUILDUP_US", "BUILDUP_THEM", "MIDFIELD", "FOUL_US", "FOUL_THEM", "CORNER_US", "CORNER_THEM", "OFFSIDE_US", "OFFSIDE_THEM", "CROWD", "KEEPER_US", "YELLOW_THEM", "YELLOW_US", "SUB_THEM" }
local FILLER_ATTACK = { "ME_RUN", "ME_CALL", "TEAM_PRESS" }
local FILLER_DEFENSE = { "ME_TRACK", "TEAM_DEEP" }

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
	momentTarget: number,
	lastMomentSlot: number,
	usedFiller: { [string]: boolean },
	effort: number,
	focus: string,
	stamina: number,
	tiredSaid: number,
	active: any?, -- moment episode in play
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
	return math.clamp(match.away.ovr + 4, 30, 90)
end

local function edge(match: Match): number
	return (match.away.ovr - match.home.ovr) * 0.02
end

-- Low stamina: less accurate, less time.
local function freshness(match: Match): number
	return 0.75 + 0.25 * match.stamina / 100
end

local function playerSkill(match: Match, base: number): number
	local ovr = if typeof(match.career.ovr) == "number" then match.career.ovr else base
	return math.clamp(math.max(base, ovr) * freshness(match), 20, 90)
end

local function timeFactor(match: Match): number
	return (0.85 + 0.075 * match.effort) * freshness(match)
end

local function gaussian(rng: Random): number
	local u1 = math.max(rng:NextNumber(), 1e-9)
	local u2 = rng:NextNumber()
	return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
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
	local s = match.stats
	return {
		stamina = math.floor(match.stamina * 10 + 0.5) / 10,
		effort = match.effort,
		focus = match.focus,
		minute = match.minute,
		goals = s.goals,
		assists = s.assists,
		shots = s.shots,
		passes = s.passes,
		goodPasses = s.goodPasses,
	}
end

local function rating(match: Match): number
	local s = match.stats
	local r = 6 + s.goals * 1.1 + s.assists * 0.7 + s.goodPasses * 0.12 + s.tackles * 0.15
		- (s.shots - s.goals) * 0.08 - (s.passes - s.goodPasses) * 0.12 - s.lost * 0.12
	return math.floor(math.clamp(r, 4, 10) * 10 + 0.5) / 10
end

local function summary(match: Match)
	local s = match.stats
	local outcome = if match.homeGoals > match.awayGoals then "WIN" elseif match.homeGoals == match.awayGoals then "DRAW" else "LOSS"
	return {
		outcome = outcome,
		home = match.homeGoals,
		away = match.awayGoals,
		goals = s.goals,
		assists = s.assists,
		shots = s.shots,
		passes = s.passes,
		goodPasses = s.goodPasses,
		rating = rating(match),
		xp = 20 + s.goals * 15 + s.assists * 10 + (if outcome == "WIN" then 20 elseif outcome == "DRAW" then 10 else 0),
	}
end

local function drainTo(match: Match, minute: number)
	local minutes = math.max(0, minute - match.minute)
	match.stamina = math.clamp(match.stamina - minutes * STAMINA_PER_MINUTE * match.effort, 0, 100)
	match.minute = math.max(match.minute, minute)
	if match.stamina <= 0 then
		match.effort = 1 -- nothing left for more
	end
end

-- The player's moment: harder later in the match and against better clubs, with more time for a
-- fresh player who works hard.
local function newMoment(match: Match, minute: number)
	local rng = match.rng
	local seed = rng:NextInteger(1, 2 ^ 31 - 1)
	local difficulty = match.momentIndex / MOMENTS_MAX + (match.away.ovr - 60) / 60
	local defenders = if rng:NextNumber() < 0.3 + difficulty * 0.35 then 3 else 2
	local receive = rng:NextNumber() < 0.5
	local episode = {
		id = match.nextEpisodeId,
		kind = "MOMENT",
		seed = seed,
		minute = minute,
		stepRng = Random.new(seed + 1),
		layout = MomentPhysics.layout(Random.new(seed), { receive = receive, defenders = defenders, timeFactor = timeFactor(match) }),
		readyAt = nil :: number?,
		token = 0,
	}
	match.nextEpisodeId += 1
	return episode
end

-- What happens in one slot of the timeline, rolled now so the current tactics count.
local function rollSlot(match: Match, slotIndex: number, minute: number, sent: { any }): any?
	local rng = match.rng
	local remaining = SLOTS - slotIndex
	local needed = match.momentTarget - match.momentIndex
	local spaced = slotIndex - match.lastMomentSlot >= 2
	local chance = MOMENT_CHANCE * EFFORT_MOMENTS[match.effort] * (FOCUS_MOMENTS[match.focus] or 1) * (if match.stamina < 25 then 0.75 else 1)
	local isMoment = match.momentIndex < MOMENTS_MAX
		and spaced
		and slotIndex > 1
		and ((needed > 0 and remaining < needed * 2) or rng:NextNumber() < chance)
	local function line(key: string, number: number?)
		table.insert(sent, { minute = minute, key = key, number = number, score = score(match) })
	end

	if isMoment then
		match.momentIndex += 1
		match.lastMomentSlot = slotIndex
		local moment = newMoment(match, minute)
		-- The build-up: who has it and how, then the call to play.
		local layout = moment.layout
		table.insert(sent, { minute = minute, key = "CHANCE", score = score(match), chance = true })
		line(if layout.kind == "RECEIVE" then "BUILD_RECEIVE" else "BUILD_ONBALL", TEAMMATE_NUMBERS[2])
		line("PROMPT")
		return moment
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

local function momentPayload(match: Match, episode)
	return {
		kind = episode.layout.kind,
		minute = episode.minute,
		index = match.momentIndex,
		number = TEAMMATE_NUMBERS[2],
		episode = { episodeId = episode.id, kind = "MOMENT", layout = episode.layout },
	}
end

-- Sends the next slot of the timeline (with any whistle before it), or full time with the result.
local function advance(player: Player, match: Match)
	if match.finished or match.active then
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
			remotes.MatchUpdate:FireClient(player, { events = sent, score = score(match), state = state(match), moment = momentPayload(match, moment) })
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

local function shotPayload(result, spot: Vector3)
	local sim = result.sim
	return {
		spot = spot,
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
	}
end

-- A teammate finishes your pass (a header if it came in high). A goal is your assist.
local function teammateFinish(match: Match, episode, receiver: number, spot: Vector3, header: boolean)
	local rng = episode.stepRng
	local side = if rng:NextNumber() < 0.5 then -1 else 1
	local input
	if header then
		input = { aimX = side * (0.25 + rng:NextNumber() * 0.65), aimY = rng:NextNumber() * 0.45, power = 0.2 + rng:NextNumber() * 0.3 }
	else
		input = { aimX = side * (0.35 + rng:NextNumber() * 0.5), aimY = 0.15 + rng:NextNumber() * 0.6, power = 0.55 + rng:NextNumber() * 0.3 }
	end
	local stats = { shooting = math.clamp(match.home.ovr - (if header then 18 else 12), 25, 80), keeperSkill = keeperSkill(match) }
	local distance = Vector3.new(spot.X, 0, spot.Z).Magnitude
	local result = ShotResolver.resolve(input, stats, Random.new(rng:NextInteger(1, 2 ^ 31 - 1)), {
		start = spot,
		scatterScale = math.max(1, distance / Moment.FinishScatterDistance),
	})
	if result.outcome == "GOAL" then
		match.homeGoals += 1
		match.stats.assists += 1
	end
	local payload = shotPayload(result, spot)
	payload.receiver = receiver
	payload.header = header
	payload.number = TEAMMATE_NUMBERS[receiver]
	return payload
end

local function sendResult(player: Player, match: Match, episode, payload)
	payload.episodeId = episode.id
	payload.kind = "MOMENT"
	payload.match = true
	payload.score = score(match)
	payload.state = state(match)
	remotes.EpisodeResult:FireClient(player, payload)
end

-- Too late: the presser gets there first.
local function tackle(player: Player, match: Match, episode)
	if match.active ~= episode then
		return
	end
	match.active = nil
	match.stats.lost += 1
	sendResult(player, match, episode, { step = episode.layout.step, action = "TACKLE", outcome = "TACKLED", detail = "TACKLED", tackler = episode.layout.tackler })
end

-- The step's intro is over on the client: the decision clock starts, and the tackle is scheduled
-- (aiming time plus the strike screen, plus network slack).
local function onReady(player: Player, match: Match, step: any)
	local episode = match.active
	if not episode or episode.readyAt or step ~= episode.layout.step then
		return
	end
	episode.readyAt = os.clock()
	episode.token += 1
	local token = episode.token
	local deadline = episode.layout.tackleTime + Moment.StrikeTime + Moment.MaxLag + Moment.Grace
	task.delay(deadline, function()
		if matches[player] == match and match.active == episode and episode.token == token then
			tackle(player, match, episode)
		end
	end)
end

local function setEffort(match: Match, value: any)
	if typeof(value) == "number" and (value == 1 or value == 2 or value == 3) and not (value > 1 and match.stamina <= 0) then
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
		onReady(player, match, value) -- once per step, so no rate limit needed
		return
	end
	if action == "NEXT" and passesRateLimit(match) then
		advance(player, match)
	end
end

local function isNumber(value: any, min: number, max: number): boolean
	return typeof(value) == "number" and value == value and value >= min and value <= max
end

local function reject(player: Player, episodeId: any, reason: string)
	warn(string.format("[MatchService] %s: rejected moment input %s (%s)", player.Name, tostring(episodeId), reason))
	remotes.EpisodeResult:FireClient(player, { episodeId = if typeof(episodeId) == "number" then episodeId else nil, kind = "MOMENT", rejected = true, reason = reason, match = true })
end

local function onMomentInput(player: Player, episodeId: any, step: any, dirX: any, dirZ: any, length: any, hitX: any, hitY: any, aimTime: any)
	local match = matches[player]
	if not match then
		return
	end
	local episode = match.active
	if not episode or episodeId ~= episode.id or step ~= episode.layout.step then
		reject(player, episodeId, "unknown or already finished step")
		return
	end
	if not passesRateLimit(match) then
		reject(player, episodeId, "too many requests")
		return
	end
	if not (isNumber(dirX, -1, 1) and isNumber(dirZ, -1, 1) and isNumber(length, 0, 1000) and isNumber(hitX, -1.5, 1.5) and isNumber(hitY, -1.5, 1.5)) then
		reject(player, episodeId, "invalid input values")
		return
	end
	local dir = Vector3.new(dirX, 0, dirZ)
	if dir.Magnitude < 0.5 or not episode.readyAt then
		reject(player, episodeId, "invalid input values")
		return
	end
	dir = dir.Unit
	local layout = episode.layout
	local elapsed = os.clock() - episode.readyAt
	-- When the arrow was let go: the client's clock, never ahead of ours and no older than the
	-- strike screen plus lag allows.
	local earliest = math.max(0, elapsed - Moment.StrikeTime - Moment.MaxLag - Moment.Grace)
	local released = if isNumber(aimTime, 0, 1000) then math.clamp(aimTime, earliest, elapsed) else earliest
	if released > layout.tackleTime + Moment.Grace then
		tackle(player, match, episode)
		return
	end

	-- This step is used up whatever happens next.
	episode.token += 1
	episode.readyAt = nil
	local stats = match.stats
	local length_ = math.clamp(length, Moment.MinArrow, Moment.MaxArrow)
	local target = layout.carrier + dir * length_
	local strike = MomentPhysics.strike(hitX, hitY)
	local rng = episode.stepRng

	if MomentPhysics.classify(layout, target) == "SHOT" then
		match.active = nil
		local shot = MomentPhysics.shotInput(layout, target, strike, math.max(0, -target.Z))
		local spot = MomentPhysics.shotSpot(layout)
		local result = ShotResolver.resolve({ aimX = shot.aimX, aimY = shot.aimY, power = shot.power }, {
			shooting = playerSkill(match, ShotConfig.DefaultShooting),
			keeperSkill = keeperSkill(match),
		}, Random.new(rng:NextInteger(1, 2 ^ 31 - 1)), {
			start = spot,
			scatterScale = shot.scatterScale,
			keeperDelay = shot.keeperDelay,
			aimPoint = shot.aimPoint,
			spin = shot.spin,
		})
		stats.shots += 1
		local payload = shotPayload(result, spot)
		-- Straight at a defender: blocked, whatever the keeper would have done.
		local blockIndex, blocker = MomentPhysics.blockShot(layout, result.sim.path, released)
		if blockIndex then
			local path = table.move(result.sim.path, 1, blockIndex, 1, {})
			local at = path[blockIndex]
			local incoming = (at - path[math.max(1, blockIndex - 1)]) / ShotConfig.Physics.SampleStep
			for i, p in MomentPhysics.deflect(at, incoming, rng) do
				if i > 1 then
					table.insert(path, p)
				end
			end
			local blockTime = (blockIndex - 1) * ShotConfig.Physics.SampleStep
			payload.path = path
			payload.events = { { kind = "bounce", t = blockTime, pos = at } }
			payload.held = false
			payload.keeperKind = nil
			payload.keeperTime = nil
			payload.keeperDives = false
			payload.keeperTarget = Vector3.new(ShotConfig.Goalkeeper.HomeX, ShotConfig.Goalkeeper.HomeY, 0)
			payload.decisiveTime = blockTime + 0.15
			payload.outcome = "MISS"
			payload.detail = "BLOCKED"
			payload.blocker = blocker
			payload.blockTime = blockTime
		elseif result.outcome == "GOAL" then
			stats.goals += 1
			match.homeGoals += 1
		end
		payload.step = layout.step
		payload.action = "SHOT"
		payload.target = target
		payload.strike = strike
		sendResult(player, match, episode, payload)
		return
	end

	-- A pass: your skill and how cleanly you struck it decide how true it runs.
	local accuracy = PassConfig.Accuracy
	local skill = playerSkill(match, PassConfig.DefaultPassing) / 100
	local sloppy = (1 + 2.2 * strike.scuff) * (if strike.lofted then 1.4 else 1)
	local cap = accuracy.MaxSigmas
	local angle = math.rad(math.clamp(gaussian(rng), -cap, cap) * (accuracy.AngleAtZeroSkill + (accuracy.AngleAtMaxSkill - accuracy.AngleAtZeroSkill) * skill) * sloppy)
	local stretch = 1 + math.clamp(gaussian(rng), -cap, cap) * (accuracy.DistanceAtZeroSkill + (accuracy.DistanceAtMaxSkill - accuracy.DistanceAtZeroSkill) * skill) * sloppy
	local reaction = Moment.DefReaction + (rng:NextNumber() * 2 - 1) * 0.05
	local c, s = math.cos(angle), math.sin(angle)
	local passDir = Vector3.new(dir.X * c - dir.Z * s, 0, dir.X * s + dir.Z * c)
	local distance = math.min(length_, Moment.MaxPassRange) * stretch * (1 - 0.3 * strike.scuff)
	local start = layout.carrier + Vector3.new(0, ShotConfig.Ball.Radius, 0)
	local v0, spin = MomentPhysics.launch(start, passDir, distance, strike)
	local sim = MomentPhysics.simulatePass(layout, v0, spin, released, reaction)
	stats.passes += 1
	local payload = {
		step = layout.step,
		action = "PASS",
		lofted = strike.lofted,
		strike = strike,
		target = target,
		detail = sim.detail,
		outcome = sim.outcome,
		releaseTime = released,
		sampleStep = MomentPhysics.SampleStep,
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
		local receiver = sim.receiver
		if MomentPhysics.shouldFinish(sim.meet) or layout.step >= Moment.MaxSteps then
			match.active = nil
			payload.finish = teammateFinish(match, episode, receiver, MomentPhysics.finishSpot(sim.meet, sim.header), sim.header)
		else
			-- One-two: he plays it straight back into your run.
			local nextLayout = MomentPhysics.oneTwo(rng, layout, receiver, sim.mateEnd[receiver], sim.defenderEnd, timeFactor(match))
			episode.layout = nextLayout
			payload.continue = { layout = nextLayout }
		end
	else
		match.active = nil
	end
	sendResult(player, match, episode, payload)
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
		momentTarget = rng:NextInteger(MOMENTS_MIN, MOMENTS_MAX - 1),
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
	remotes.MomentInput.OnServerEvent:Connect(onMomentInput)
	Players.PlayerRemoving:Connect(function(player)
		matches[player] = nil
	end)
end

return MatchService
