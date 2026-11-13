-- The match after training: a simulated 90 minutes with 6-9 moments the player plays himself.
-- Everything is decided here; the client only shows it and sends the player's input.
--
-- Flow (MatchRequest: client -> server, MatchUpdate: server -> client):
--   CareerService "START_MATCH" -> MatchService.start: builds the schedule, returns the header.
--   "NEXT"   -> MatchUpdate { events, moment } or { events, result }: the simulated events up to the
--               player's next moment (commentary keys, see ShotClient/Commentary), or to full time.
--   "SHOOT" / "PASS" -> the moment starts as an episode on the training remotes (EpisodeStarted,
--               SubmitEpisodeInput, EpisodeResult), resolved by EpisodeService's resolvers.
--               CHOICE moments (you have the ball) take either; RECEIVE moments (a teammate found
--               you) only SHOOT.
--   "AUTO"   -> after your good pass: the teammate's shot, simulated here and sent as an episode
--               that already carries its result (episode.auto). A goal counts as your assist.
-- The result is saved once, by CareerService.onMatchFinished, when full time is sent.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShotConfig = require(Shared:WaitForChild("ShotConfig"))
local PassConfig = require(Shared:WaitForChild("PassConfig"))
local PassPhysics = require(Shared:WaitForChild("PassPhysics"))
local CareerConfig = require(Shared:WaitForChild("CareerConfig"))
local EpisodeService = require(script.Parent.EpisodeService)
local ShotResolver = require(script.Parent.ShotResolver)

local MOMENTS_MIN, MOMENTS_MAX = 6, 9
local MIN_REMOTE_INTERVAL = 0.2
local FIRST_EPISODE_ID = 100000 -- kept apart from training episode ids
local TEAMMATE_NUMBERS = { 7, 28 } -- pass drill teammates 1 and 2 (see PassVisuals)
-- Where a teammate's pass finds you (RECEIVE moments): ball spots in front of goal.
local RECEIVE_SPOTS = { { -13, 34 }, { 12, 32 }, { -6, 28 }, { 8, 38 }, { 0, 30 }, { -16, 40 }, { 15, 26 } }

type Event = { minute: number, key: string, number: number?, moment: string? }
type Match = {
	career: any,
	home: CareerConfig.Club,
	away: CareerConfig.Club,
	rng: Random,
	events: { Event },
	cursor: number,
	homeGoals: number,
	awayGoals: number,
	momentIndex: number,
	momentTotal: number,
	moment: Event?, -- waiting for SHOOT / PASS
	active: any?, -- episode in play
	auto: any?, -- good pass waiting for the teammate's shot
	nextEpisodeId: number,
	lastRemoteAt: number,
	stats: { goals: number, assists: number, shots: number, passes: number, goodPasses: number },
	finished: boolean,
}

local MatchService = {}

local matches: { [Player]: Match } = {}
local remotes
local hooks = nil :: { onMatchFinished: (Player, any) -> any }?

local function keeperSkill(match: Match): number
	return math.clamp(match.away.ovr - 8, 30, 80)
end

-- The whole match up front: the player's moments at random minutes, chances for both sides in
-- between, and the fixed whistles. Goals of simulated chances are decided here too.
local function buildSchedule(rng: Random, home: CareerConfig.Club, away: CareerConfig.Club): ({ Event }, number)
	local events: { Event } = {}
	local used = { [45] = true }
	local function freeMinute(from: number, to: number): number
		for _ = 1, 40 do
			local minute = rng:NextInteger(from, to)
			if not used[minute] then
				used[minute] = true
				return minute
			end
		end
		return from
	end

	local total = rng:NextInteger(MOMENTS_MIN, MOMENTS_MAX)
	for i = 1, total do
		-- Spread over the match: one moment per slice of the 90 minutes.
		local from = math.floor(3 + (i - 1) * 84 / total)
		local to = math.max(from, math.floor(3 + i * 84 / total) - 1)
		table.insert(events, { minute = freeMinute(from, to), key = "MOMENT", moment = if rng:NextNumber() < 0.55 then "CHOICE" else "RECEIVE" })
	end

	local edge = (away.ovr - home.ovr) * 0.02
	for _ = 1, rng:NextInteger(3, 5) do
		local roll = rng:NextNumber()
		local goalChance = math.clamp(0.26 + edge, 0.14, 0.45)
		local key = if roll < goalChance then "OPP_GOAL" elseif roll < goalChance + 0.4 then "OPP_SAVE" else "OPP_MISS"
		table.insert(events, { minute = freeMinute(4, 88), key = key })
	end
	for _ = 1, rng:NextInteger(1, 3) do
		local key = if rng:NextNumber() < math.clamp(0.2 - edge, 0.1, 0.35) then "TEAM_GOAL" else "TEAM_MISS"
		table.insert(events, { minute = freeMinute(4, 88), key = key, number = TEAMMATE_NUMBERS[rng:NextInteger(1, #TEAMMATE_NUMBERS)] })
	end
	table.insert(events, { minute = 0, key = "KICKOFF" })
	table.insert(events, { minute = 45, key = "HALFTIME" })
	table.insert(events, { minute = 90, key = "FULLTIME" })
	table.sort(events, function(a, b)
		return a.minute < b.minute
	end)
	return events, total
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

local function summary(match: Match)
	local s = match.stats
	local outcome = if match.homeGoals > match.awayGoals then "WIN" elseif match.homeGoals == match.awayGoals then "DRAW" else "LOSS"
	local rating = 6 + s.goals * 1.1 + s.assists * 0.7 + s.goodPasses * 0.15 - (s.shots - s.goals) * 0.1 - (s.passes - s.goodPasses) * 0.15
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

-- Sends the simulated events up to the player's next moment, or to full time with the result.
local function advance(player: Player, match: Match)
	if match.finished or match.moment or match.active or match.auto then
		return
	end
	local sent = {}
	while match.cursor <= #match.events do
		local event = match.events[match.cursor]
		match.cursor += 1
		if event.key == "OPP_GOAL" then
			match.awayGoals += 1
		elseif event.key == "TEAM_GOAL" then
			match.homeGoals += 1
		end
		if event.key == "MOMENT" then
			match.momentIndex += 1
			match.moment = event
			local number = TEAMMATE_NUMBERS[match.rng:NextInteger(1, #TEAMMATE_NUMBERS)]
			remotes.MatchUpdate:FireClient(player, {
				events = sent,
				score = score(match),
				moment = { kind = event.moment, minute = event.minute, index = match.momentIndex, total = match.momentTotal, number = number },
			})
			return
		end
		table.insert(sent, { minute = event.minute, key = event.key, number = event.number, score = score(match) })
	end

	match.finished = true
	local result = summary(match)
	local reward = hooks and hooks.onMatchFinished(player, result)
	print(string.format(
		"[MatchService] %s: full time %d:%d, goals %d, assists %d, rating %.1f",
		player.Name, match.homeGoals, match.awayGoals, result.goals, result.assists, result.rating
	))
	remotes.MatchUpdate:FireClient(player, { events = sent, score = score(match), result = result, career = reward })
	matches[player] = nil
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

local function startMoment(player: Player, match: Match, choice: string)
	local moment = match.moment
	if not moment or match.active then
		return
	end
	if choice == "PASS" and moment.moment ~= "CHOICE" then
		return -- a teammate found you: this one is yours to finish
	end
	match.moment = nil
	local episode
	if choice == "PASS" then
		episode = newEpisode(match, "PASS")
		-- The situation is picked from the seed too, so (seed, input) reproduces the whole pass.
		local rng = Random.new(episode.seed)
		episode.layout = PassPhysics.layout(rng:NextInteger(2, #PassConfig.Layouts), rng:NextNumber() * 2)
	else
		episode = newEpisode(match, "SHOT")
		if (moment.moment :: string) == "RECEIVE" then
			local spot = RECEIVE_SPOTS[match.rng:NextInteger(1, #RECEIVE_SPOTS)]
			episode.match.spot = Vector3.new(spot[1], ShotConfig.Ball.Radius, spot[2])
		end
	end
	match.active = episode
	remotes.EpisodeStarted:FireClient(player, episodePayload(episode, if choice == "PASS" then "PASS" else "SHOT"))
end

-- After your good pass: the teammate shoots. Aim and power are his own, so some go in and some don't.
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
	local input = {
		aimX = side * (0.35 + rng:NextNumber() * 0.5),
		aimY = 0.15 + rng:NextNumber() * 0.6,
		power = 0.55 + rng:NextNumber() * 0.3,
	}
	local stats = { shooting = math.clamp(match.home.ovr - 12, 30, 80), keeperSkill = keeperSkill(match) }
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
	-- Same fields as an EpisodeResult for a shot: the client replays this path.
	payload.auto = {
		episodeId = episode.id,
		kind = "SHOT",
		mode = "AUTO",
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

local function onRequest(player: Player, action: any)
	local match = matches[player]
	if not match or typeof(action) ~= "string" or not passesRateLimit(match) then
		return
	end
	if action == "NEXT" then
		advance(player, match)
	elseif action == "SHOOT" or action == "PASS" then
		startMoment(player, match, action)
	elseif action == "AUTO" then
		autoShot(player, match)
	end
end

local function reject(player: Player, episodeId: any, reason: string)
	warn(string.format("[MatchService] %s: rejected input for episode %s (%s)", player.Name, tostring(episodeId), reason))
	remotes.EpisodeResult:FireClient(player, { episodeId = if typeof(episodeId) == "number" then episodeId else nil, rejected = true, reason = reason, match = true })
end

local function onSubmit(player: Player, episodeId: any, a: any, b: any, power: any, clientTime: any)
	local match = matches[player]
	if not match or not passesRateLimit(match) then
		return
	end
	local active = match.active
	if not active or episodeId ~= active.id then
		reject(player, episodeId, "unknown or already finished episode")
		return
	end
	local inRange = EpisodeService.isNumberInRange
	local pass = active.kind == "PASS"
	if not (inRange(a, -1, 1) and inRange(b, if pass then -1 else 0, 1) and inRange(power, 0, 1)) then
		reject(player, episodeId, "invalid input values")
		return
	end
	local elapsed = os.clock() - active.startedAt
	if elapsed < ShotConfig.Episode.MinThinkTime then
		reject(player, episodeId, "input too early")
		return
	end

	local success, outcome, detail, speedKmh, payload
	if pass then
		success, outcome, detail, speedKmh, payload = EpisodeService.resolvePass(active, math.clamp(a, -1, 1), math.clamp(b, -1, 1), power, clientTime)
		if success == nil then
			reject(player, episodeId, "invalid input values")
			return
		end
	else
		success, outcome, detail, speedKmh, payload = EpisodeService.resolveShot(active, a, b, power)
	end

	-- Consume the episode once it has a result, so it can never produce a second one.
	match.active = nil
	local stats = match.stats
	if pass then
		stats.passes += 1
		if success and payload.receiver and payload.receiverTrack then
			stats.goodPasses += 1
			-- The receiver takes it towards goal and shoots (autoShot).
			local meet = payload.receiverTrack[#payload.receiverTrack]
			local toGoal = Vector3.new(-meet.X, 0, -meet.Z).Unit
			local ground = meet + toGoal * PassConfig.Teammate.Reach * 0.7
			match.auto = { spot = Vector3.new(ground.X, ShotConfig.Ball.Radius, ground.Z), receiver = payload.receiver }
			payload.followUp = true
		end
	else
		stats.shots += 1
		if success then
			stats.goals += 1
			match.homeGoals += 1
		end
	end

	payload.episodeId = active.id
	payload.kind = active.kind
	payload.mode = "MATCH"
	payload.match = true
	payload.outcome = outcome
	payload.detail = detail
	payload.speedKmh = speedKmh
	payload.score = score(match)
	remotes.EpisodeResult:FireClient(player, payload)
end

-- CareerService "START_MATCH": a new match against the career's next opponent.
function MatchService.start(player: Player, career: any)
	local home = CareerConfig.club(career.clubId)
	if not home then
		return nil
	end
	local away = CareerConfig.firstOpponent(home)
	local rng = Random.new()
	local events, total = buildSchedule(rng, home, away)
	matches[player] = {
		career = career,
		home = home,
		away = away,
		rng = rng,
		events = events,
		cursor = 1,
		homeGoals = 0,
		awayGoals = 0,
		momentIndex = 0,
		momentTotal = total,
		nextEpisodeId = FIRST_EPISODE_ID,
		lastRemoteAt = -math.huge,
		stats = { goals = 0, assists = 0, shots = 0, passes = 0, goodPasses = 0 },
		finished = false,
	}
	print(string.format("[MatchService] %s: %s - %s, %d moments", player.Name, home.id, away.id, total))
	return { homeId = home.id, awayId = away.id, moments = total }
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

return MatchService
