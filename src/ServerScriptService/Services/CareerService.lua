-- Owns each player's career: loads and saves it (DataStore), validates new careers and settings,
-- and hands the player to EpisodeService for training. The client asks through the CareerRequest
-- RemoteFunction: (action, payload) -> { ok = true, ... } or { ok = false, error = CODE }.
--
-- Actions:
--   GET             -> career?, settings, persistent (false: progress won't survive this session)
--   CREATE          { clubId, firstName, lastName, number, replace } -> career
--   START_TRAINING  -> stage; puts the player into training at the career's saved stage
--   SETTINGS        { shake, bigUi } -> settings
--   DELETE          -> removes the career
--   START_MATCH     -> header { homeId, awayId, moments }; needs the training done (MatchService)
--
-- Training progress (career.training: SHOT -> PASS -> DONE) only moves forward, and only when
-- EpisodeService reports a completed task, so the client can't skip it.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CareerConfig = require(Shared:WaitForChild("CareerConfig"))
local ShotConfig = require(Shared:WaitForChild("ShotConfig"))

local STORE_NAME = "NfsCareer_v1"
local DATA_VERSION = 1
local LOAD_ATTEMPTS = 3
local LOAD_WAIT = 15 -- seconds a request waits for the player's save to load
local MIN_REQUEST_INTERVAL = 0.2
local TRAINING_ORDER = { SHOT = 1, PASS = 2, DONE = 3 }

type Career = {
	clubId: string,
	firstName: string,
	lastName: string,
	number: number,
	ovr: number,
	level: number,
	training: string, -- SHOT | PASS | DONE
	createdAt: number,
	xp: number,
	matches: number,
	goals: number,
	assists: number,
}
type Settings = { shake: boolean, bigUi: boolean }
type Profile = {
	loaded: boolean,
	persistent: boolean,
	career: Career?,
	settings: Settings,
	lastRequestAt: number,
	busy: boolean,
	saving: boolean,
	dirty: boolean,
}

local CareerService = {}

local profiles: { [Player]: Profile } = {}
local hooks = nil :: { beginTraining: (Player, string) -> (), stopTraining: (Player) -> (), startMatch: (Player, any) -> any }?

local store: DataStore? = nil
do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = result
	else
		warn("[CareerService] DataStore unavailable, careers last for this session only:", result)
	end
end

local function defaultSettings(): Settings
	return { shake = true, bigUi = false }
end

local function key(player: Player): string
	return "player_" .. player.UserId
end

local XP_PER_LEVEL = 100

-- Non-negative whole number from saved data (0 if missing or broken).
local function count(value: any): number
	return if typeof(value) == "number" and value == value and value >= 0 then math.floor(value) else 0
end

-- Saved data comes back exactly as stored, but is checked anyway so a bad record can't break
-- the menus or the training.
local function readCareer(data: any): Career?
	if typeof(data) ~= "table" then
		return nil
	end
	local club = CareerConfig.club(data.clubId)
	local first = CareerConfig.cleanName(data.firstName)
	local last = CareerConfig.cleanName(data.lastName)
	if not (club and first and last and CareerConfig.validNumber(data.number) and TRAINING_ORDER[data.training]) then
		return nil
	end
	return {
		clubId = club.id,
		firstName = first,
		lastName = last,
		number = data.number,
		ovr = if typeof(data.ovr) == "number" then data.ovr else CareerConfig.StartOvr,
		level = if typeof(data.level) == "number" then data.level else 1,
		training = data.training,
		createdAt = if typeof(data.createdAt) == "number" then data.createdAt else 0,
		xp = count(data.xp),
		matches = count(data.matches),
		goals = count(data.goals),
		assists = count(data.assists),
	}
end

local function readSettings(data: any): Settings
	local settings = defaultSettings()
	if typeof(data) == "table" then
		if typeof(data.shake) == "boolean" then
			settings.shake = data.shake
		end
		if typeof(data.bigUi) == "boolean" then
			settings.bigUi = data.bigUi
		end
	end
	return settings
end

local function save(player: Player, profile: Profile)
	if not (store and profile.persistent) then
		return
	end
	if profile.saving then
		profile.dirty = true
		return
	end
	profile.saving = true
	repeat
		profile.dirty = false
		local data = { version = DATA_VERSION, career = profile.career, settings = profile.settings }
		local ok, err = pcall(function()
			(store :: DataStore):SetAsync(key(player), data, { player.UserId })
		end)
		if not ok then
			warn(string.format("[CareerService] %s: save failed: %s", player.Name, tostring(err)))
		end
	until not profile.dirty
	profile.saving = false
end

local function queueSave(player: Player, profile: Profile)
	task.spawn(save, player, profile)
end

local function load(player: Player)
	local profile: Profile = {
		loaded = false,
		persistent = false,
		career = nil,
		settings = defaultSettings(),
		lastRequestAt = -math.huge,
		busy = false,
		saving = false,
		dirty = false,
	}
	profiles[player] = profile
	if store then
		for attempt = 1, LOAD_ATTEMPTS do
			local ok, data = pcall(function()
				return (store :: DataStore):GetAsync(key(player))
			end)
			if ok then
				-- Only a successful load may be saved over; otherwise an outage would wipe the career.
				profile.persistent = true
				if typeof(data) == "table" then
					profile.career = readCareer(data.career)
					profile.settings = readSettings(data.settings)
				end
				break
			end
			warn(string.format("[CareerService] %s: load attempt %d failed: %s", player.Name, attempt, tostring(data)))
			if attempt < LOAD_ATTEMPTS then
				task.wait(attempt)
			end
		end
	end
	profile.loaded = true
	print(string.format(
		"[CareerService] %s: profile loaded (%s, %s)",
		player.Name, if profile.career then "career at " .. profile.career.clubId else "no career", if profile.persistent then "saved" else "session only"
	))
end

local function publicCareer(career: Career?)
	if not career then
		return nil
	end
	return table.clone(career)
end

-- Returns the name as other players would see it, or nil and an error code.
local function filterName(player: Player, name: string): (string?, string?)
	local ok, result = pcall(function()
		local filtered = TextService:FilterStringAsync(name, player.UserId, Enum.TextFilterContext.PublicChat)
		return filtered:GetNonChatStringForBroadcastAsync()
	end)
	if not ok then
		warn(string.format("[CareerService] %s: text filter failed: %s", player.Name, tostring(result)))
		return nil, "FILTER_FAILED"
	end
	if result ~= name then
		return nil, "NAME_FILTERED"
	end
	return result, nil
end

local function createCareer(player: Player, profile: Profile, payload: any)
	if typeof(payload) ~= "table" then
		return { ok = false, error = "BAD_REQUEST" }
	end
	if profile.career and payload.replace ~= true then
		return { ok = false, error = "CAREER_EXISTS" }
	end
	local club = CareerConfig.club(payload.clubId)
	if not club then
		return { ok = false, error = "BAD_REQUEST" }
	end
	if not club.open then
		return { ok = false, error = "CLUB_LOCKED" }
	end
	local first, firstError = CareerConfig.cleanName(payload.firstName)
	if not first then
		return { ok = false, error = "FIRST_" .. tostring(firstError) }
	end
	local last, lastError = CareerConfig.cleanName(payload.lastName)
	if not last then
		return { ok = false, error = "LAST_" .. tostring(lastError) }
	end
	if not CareerConfig.validNumber(payload.number) then
		return { ok = false, error = "BAD_NUMBER" }
	end
	local filteredFirst, filterError = filterName(player, first)
	if not filteredFirst then
		return { ok = false, error = filterError }
	end
	local filteredLast
	filteredLast, filterError = filterName(player, last)
	if not filteredLast then
		return { ok = false, error = filterError }
	end
	if profiles[player] ~= profile then
		return { ok = false, error = "NOT_LOADED" } -- left while the filter was running
	end

	if hooks then
		hooks.stopTraining(player)
	end
	profile.career = {
		clubId = club.id,
		firstName = filteredFirst,
		lastName = filteredLast,
		number = payload.number,
		ovr = CareerConfig.StartOvr,
		level = 1,
		training = if ShotConfig.Training.StartStage == "PASS" then "PASS" else "SHOT",
		createdAt = os.time(),
		xp = 0,
		matches = 0,
		goals = 0,
		assists = 0,
	}
	queueSave(player, profile)
	print(string.format("[CareerService] %s: new career at %s, #%d", player.Name, club.id, payload.number))
	return { ok = true, career = publicCareer(profile.career) }
end

local function handle(player: Player, profile: Profile, action: string, payload: any)
	if action == "GET" then
		return { ok = true, career = publicCareer(profile.career), settings = table.clone(profile.settings), persistent = profile.persistent }
	elseif action == "CREATE" then
		return createCareer(player, profile, payload)
	elseif action == "START_TRAINING" then
		local career = profile.career
		if not career then
			return { ok = false, error = "NO_CAREER" }
		end
		if career.training == "DONE" then
			return { ok = false, error = "TRAINING_DONE" }
		end
		if hooks then
			hooks.beginTraining(player, career.training)
		end
		return { ok = true, stage = career.training }
	elseif action == "START_MATCH" then
		local career = profile.career
		if not career then
			return { ok = false, error = "NO_CAREER" }
		end
		if career.training ~= "DONE" then
			return { ok = false, error = "TRAINING_FIRST" }
		end
		local header = hooks and hooks.startMatch(player, career)
		if not header then
			return { ok = false, error = "SERVER_ERROR" }
		end
		return { ok = true, match = header }
	elseif action == "SETTINGS" then
		if typeof(payload) ~= "table" then
			return { ok = false, error = "BAD_REQUEST" }
		end
		profile.settings = readSettings({
			shake = if typeof(payload.shake) == "boolean" then payload.shake else profile.settings.shake,
			bigUi = if typeof(payload.bigUi) == "boolean" then payload.bigUi else profile.settings.bigUi,
		})
		queueSave(player, profile)
		return { ok = true, settings = table.clone(profile.settings) }
	elseif action == "DELETE" then
		if hooks then
			hooks.stopTraining(player)
		end
		profile.career = nil
		queueSave(player, profile)
		return { ok = true }
	end
	return { ok = false, error = "BAD_REQUEST" }
end

local function onInvoke(player: Player, action: any, payload: any)
	local profile = profiles[player]
	local waited = 0
	while profile and not profile.loaded and waited < LOAD_WAIT do
		waited += task.wait(0.1)
		profile = profiles[player]
	end
	if not (profile and profile.loaded) then
		return { ok = false, error = "NOT_LOADED" }
	end
	if typeof(action) ~= "string" then
		return { ok = false, error = "BAD_REQUEST" }
	end
	local now = os.clock()
	if profile.busy or now - profile.lastRequestAt < MIN_REQUEST_INTERVAL then
		return { ok = false, error = "BUSY" }
	end
	profile.lastRequestAt = now
	profile.busy = true
	local ok, result = pcall(handle, player, profile, action, payload)
	profile.busy = false
	if not ok then
		warn(string.format("[CareerService] %s: %s failed: %s", player.Name, action, tostring(result)))
		return { ok = false, error = "SERVER_ERROR" }
	end
	return result
end

-- MatchService: full time. Adds the match to the career once and returns the updated career.
function CareerService.onMatchFinished(player: Player, result: { xp: number, goals: number, assists: number })
	local profile = profiles[player]
	local career = profile and profile.career
	if not (profile and career) then
		return nil
	end
	career.matches += 1
	career.goals += result.goals
	career.assists += result.assists
	career.xp += result.xp
	career.level = 1 + career.xp // XP_PER_LEVEL
	queueSave(player, profile)
	return publicCareer(career)
end

-- EpisodeService: the player finished a training task (stage SHOT or PASS).
function CareerService.onStageCompleted(player: Player, stage: string)
	local profile = profiles[player]
	local career = profile and profile.career
	if not (profile and career) then
		return
	end
	local nextStage = if stage == "SHOT" then "PASS" elseif stage == "PASS" then "DONE" else nil
	if nextStage and TRAINING_ORDER[nextStage] > TRAINING_ORDER[career.training] then
		career.training = nextStage
		queueSave(player, profile)
		print(string.format("[CareerService] %s: training stage %s done -> %s", player.Name, stage, nextStage))
	end
end

function CareerService.init(remote: RemoteFunction, trainingHooks)
	if hooks then
		warn("[CareerService] init called twice; ignoring")
		return
	end
	hooks = trainingHooks
	remote.OnServerInvoke = onInvoke
	Players.PlayerAdded:Connect(load)
	for _, player in Players:GetPlayers() do
		task.spawn(load, player)
	end
	Players.PlayerRemoving:Connect(function(player)
		local profile = profiles[player]
		profiles[player] = nil
		if profile and profile.loaded then
			save(player, profile)
		end
	end)
	game:BindToClose(function()
		local pending = 0
		for player, profile in profiles do
			if profile.loaded then
				pending += 1
				task.spawn(function()
					save(player, profile)
					pending -= 1
				end)
			end
		end
		local started = os.clock()
		while pending > 0 and os.clock() - started < 25 do
			task.wait(0.1)
		end
	end)
end

return CareerService
