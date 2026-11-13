-- Client entry point: the career menus first (CareerMenu), then the shot and pass training, which
-- wires input, both drills' 3D visuals, the HUD and the finger hint to the server remotes, and the
-- match: the commentator's studio (MatchHud) and your moments on the pitch (MomentVisuals over the
-- shot drill's goal and keeper). The client sends only its input; the server decides outcomes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")

-- A single-player career: Roblox's player list only covers the HUD's top-right corner.
task.spawn(function()
	for _ = 1, 20 do
		if pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.PlayerList, false) then
			return
		end
		task.wait(0.5)
	end
end)

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShotConfig = require(Shared:WaitForChild("ShotConfig"))
local CareerConfig = require(Shared:WaitForChild("CareerConfig"))
local MomentPhysics = require(Shared:WaitForChild("MomentPhysics"))
local InputController = require(script:WaitForChild("InputController"))
local ShotVisuals = require(script:WaitForChild("ShotVisuals"))
local ShotHud = require(script:WaitForChild("ShotHud"))
local ImageLoader = require(script:WaitForChild("ImageLoader"))
local TutorialHint = require(script:WaitForChild("TutorialHint"))
local PassVisuals = require(script:WaitForChild("PassVisuals"))
local CareerMenu = require(script:WaitForChild("CareerMenu"))
local MatchHud = require(script:WaitForChild("MatchHud"))
local MomentVisuals = require(script:WaitForChild("MomentVisuals"))
local Commentary = require(script:WaitForChild("Commentary"))

local CARD_DELAY = 0.55 -- let the player see the ball hit the net before the card covers the goal
local FOLLOW_UP_DELAY = 0.75 -- after a good pass: the receiver controls it, then the shot camera
local CELEBRATION_TIME = 2.6 -- match: the scorer's celebration before the studio comes back
local AFTER_SHOT_TIME = 1.2 -- match: a missed / saved shot, before the studio comes back

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if not Remotes then
	warn("[ShotClient] Still waiting for ReplicatedStorage.Remotes. The server script (Main) has not started; check Output for red [Main] errors.")
	Remotes = ReplicatedStorage:WaitForChild("Remotes")
end
local RequestEpisode = Remotes:WaitForChild("RequestEpisode")
local EpisodeStarted = Remotes:WaitForChild("EpisodeStarted")
local SubmitEpisodeInput = Remotes:WaitForChild("SubmitEpisodeInput")
local EpisodeResult = Remotes:WaitForChild("EpisodeResult")
local CareerRequest = Remotes:WaitForChild("CareerRequest")
local MatchRequest = Remotes:WaitForChild("MatchRequest")
local MatchUpdate = Remotes:WaitForChild("MatchUpdate")
local MomentInput = Remotes:WaitForChild("MomentInput")

-- Default movement controls are useless here and would cover the screen on phones.
task.spawn(function()
	local playerModule = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 5)
	if playerModule then
		local ok, err = pcall(function()
			require(playerModule):GetControls():Disable()
		end)
		if not ok then
			warn("[ShotClient] Could not disable default controls:", err)
		end
	end
end)

local hud = ShotHud.new()
hud:setVisible(false) -- the career menu comes first
ImageLoader.watch() -- stadium banners, keeper kit and players' faces
local visuals = ShotVisuals.new()
visuals:setActive(false) -- the menu owns the camera until the training starts
local passVisuals = PassVisuals.new()
local input = InputController.new()
local hint = TutorialHint.new()
local currentEpisode = nil
local currentScene = nil -- SHOT | PASS | FOLLOWUP (training), MOMENT (match); nil in the menus
local SCENE_BLEND = 0.9 -- camera glide between scenes; input waits for it
local waitingForEpisode = false
local bestSpeed = 0 -- fastest goal in the current task attempt, for the completion menu
local inTraining = false
local inMatch = false
local matchHud = MatchHud.new()
local momentVisuals = MomentVisuals.new()
local matchUi = Commentary.ui()
local moment = nil -- the moment in play: { episodeId, layout, minute, lines, involvement }
local lastCompletedStage = nil -- stage of the last completed task (SHOT | PASS)

-- choice: "RETRY" or "NEXT" from the completion menu, otherwise nil.
local function requestEpisode(choice: string?)
	if not inTraining then
		return
	end
	waitingForEpisode = true
	RequestEpisode:FireServer(choice)
end

local function continueWith(choice: string?)
	if waitingForEpisode then
		return
	end
	hud:hideCard()
	requestEpisode(choice)
end

hud.onContinue = function()
	continueWith(nil)
end
hud.onRetry = function()
	continueWith("RETRY")
end

-- Goals panel: one pip per goal / good pass still needed in the task.
local function showProgress(info)
	local done = {}
	for _ = 1, info.goals do
		table.insert(done, if info.stage == "PASS" then "GOOD" else "GOAL")
	end
	hud:setSeries(info.goals, info.taskGoals, done)
end

-- Switches the 3D scene: SHOT (shot drill), PASS (pass drill), FOLLOWUP (pass drill's players,
-- shot drill's camera and ball), MOMENT (match: MomentVisuals owns the camera, the shot drill keeps
-- the goal and keeper), nil (menus: all put away). Returns whether the camera moves.
local function setScene(scene: string?): boolean
	if scene == currentScene then
		return false
	end
	currentScene = scene
	if scene ~= "MOMENT" then
		momentVisuals:exit()
		visuals:setCameraEnabled(true)
	end
	if scene == nil then
		visuals:setActive(false)
		passVisuals:exit()
	elseif scene == "MOMENT" then
		passVisuals:exit()
		visuals:setActive(true)
		visuals:setCameraEnabled(false)
		visuals:setSpot(MomentPhysics.shotSpot({ carrier = Vector3.new(0, 0, 64) } :: any))
	elseif scene == "PASS" then
		visuals:setActive(false)
		passVisuals:enter()
	elseif scene == "FOLLOWUP" then
		visuals:setActive(true) -- passVisuals stays, its players are on the pitch
	else
		passVisuals:exit()
		visuals:setActive(true)
	end
	return true
end

input.onShoot = function(a, b, power)
	local episode = currentEpisode
	if not episode then
		return
	end
	input:setEnabled(false)
	hint:hide()
	hud:setPowerZone(nil)
	if episode.kind == "PASS" then
		passVisuals:onPassReleased()
		hud:setTitle("PassFlying")
		SubmitEpisodeInput:FireServer(episode.episodeId, a, b, power, passVisuals:clockTime())
	else
		if episode.mode == "FOLLOWUP" then
			passVisuals:followUpKick()
		end
		visuals:onShotReleased()
		hud:setTitle("Flying")
		SubmitEpisodeInput:FireServer(episode.episodeId, a, b, power)
	end
end

local handleResult -- defined below

EpisodeStarted.OnClientEvent:Connect(function(episode)
	if not inTraining or typeof(episode) ~= "table" or (episode.kind ~= "SHOT" and episode.kind ~= "PASS") then
		return
	end
	waitingForEpisode = false
	currentEpisode = episode
	input:setEnabled(false)
	local pass = episode.kind == "PASS"
	local followUp = episode.mode == "FOLLOWUP"
	local moved = setScene(if pass then "PASS" elseif followUp then "FOLLOWUP" else "SHOT")
	if pass then
		passVisuals:reset(episode.layout)
		input:setMode("PASS", episode.layout.origin)
	elseif followUp then
		visuals:reset(episode.spot)
		passVisuals:beginFollowUp(episode.receiver, episode.spot, ShotVisuals.cameraPosition(episode.spot))
		input:setMode("SHOT")
		moved = true
	else
		visuals:reset(episode.spot)
		input:setMode("SHOT")
	end
	hud:hideCard()
	hud:setPower(0)
	showProgress(episode)
	hud:setMode(episode.stage, if followUp then episode.phaseMode else episode.mode, episode.taskGoals, episode.kind)
	if episode.shots == 0 and not followUp then
		bestSpeed = 0
	end

	local guide = episode.hint -- only sent for guided attempts
	if guide then
		hint:show(episode.kind, guide)
		hud:setPowerZone(guide.powerMin, guide.powerMax)
		input:setGuide({
			aimX = if pass then nil else guide.aimX,
			aimY = if pass then nil else guide.aimY,
			accepts = function(aimX, aimY)
				return hint:accepts(aimX, aimY)
			end,
			acceptsTarget = function(target)
				return hint:acceptsTarget(target)
			end,
			onRejected = function()
				hint:nudge()
			end,
		})
		passVisuals:setHighlight(if pass then guide.targetIndex else nil)
	else
		hint:hide()
		hud:setPowerZone(nil)
		input:setGuide(nil)
		passVisuals:setHighlight(nil)
	end
	hud:setTitle(if pass then (if guide then "PassTutorialReady" else "PassReady") elseif guide then "TutorialReady" elseif followUp then "FollowUpReady" else "Ready")

	task.delay(if moved then math.max(SCENE_BLEND, ShotConfig.Input.ReadyDelay) else ShotConfig.Input.ReadyDelay, function()
		if currentEpisode == episode then
			input:setEnabled(true)
		end
	end)
end)

-- What the card says after each training attempt, by the server's training status.
local function showOutcome(result)
	local status = result.status
	local passStage = result.stage == "PASS"
	local key = if result.kind == "PASS" then "PASS_" .. result.detail else result.detail
	local speed = result.speedKmh
	if status == "COMPLETED" then
		lastCompletedStage = result.stage
		hud:showComplete({ kind = result.stage, goals = result.goals, shots = result.shots, bestSpeed = bestSpeed, bonusGoals = result.bonusGoals })
	elseif status == "TUTORIAL_DONE" then
		hud:showResult(key, {
			subtitle = string.format(if passStage then hud.text.PassTutorialDone else hud.text.TutorialDone, result.taskGoals),
			button = hud.text.ToTask,
			speedKmh = speed,
		})
	elseif status == "TUTORIAL_RETRY" then
		hud:showResult(key, { subtitle = hud.text.TutorialRetry, speedKmh = speed })
	else
		local left = result.taskGoals - result.goals
		local subtitle = nil
		if result.mode == "FOLLOWUP" then
			subtitle = string.format(if result.outcome == "GOAL" then hud.text.FollowUpGoal else hud.text.FollowUpMiss, left)
		elseif result.mode == "TASK" and result.stage == "SHOT" and result.outcome == "GOAL" then
			subtitle = string.format(hud.text.TaskLeft, left)
		end
		hud:showResult(key, { subtitle = subtitle, speedKmh = speed })
	end
end

---------------------------------------------------------------- match moments

-- Back to the commentator: the moment's lines go into the feed, then the match goes on.
local function backToStudio(score, state)
	local m = moment
	moment = nil
	if not inMatch or not m then
		return
	end
	visuals:setCameraEnabled(false)
	visuals:setSpot(MomentPhysics.shotSpot({ carrier = Vector3.new(0, 0, 64) } :: any))
	momentVisuals:studio()
	matchHud:setMode("STUDIO")
	if state then
		matchHud:setState(state)
	end
	local events = {}
	for _, line in m.lines do
		table.insert(events, { minute = m.minute, key = line.key, number = line.number, score = line.score or score })
	end
	matchHud:playEvents(events, function()
		if inMatch then
			matchHud:addMomentChip(m.involvement)
			MatchRequest:FireServer("NEXT")
		end
	end)
end

local function addLine(key: string, number: number?, score: any?)
	if moment then
		table.insert(moment.lines, { key = key, number = number, score = score })
	end
end

local function startStep(layout)
	if not moment then
		return
	end
	moment.layout = layout
	visuals:setSpot(MomentPhysics.shotSpot(layout))
	matchHud:setHint(nil)
	momentVisuals:begin(layout)
end

local function startMoment(update)
	local payload = update.moment
	if not inMatch or typeof(payload) ~= "table" or typeof(payload.episode) ~= "table" then
		return
	end
	moment = {
		episodeId = payload.episode.episodeId,
		minute = payload.minute,
		lines = {},
		involvement = "NONE",
	}
	matchHud:setMode("PLAY")
	setScene("MOMENT")
	visuals:setCameraEnabled(false)
	startStep(payload.episode.layout)
end

momentVisuals.onReady = function(step)
	MatchRequest:FireServer("READY", step)
	matchHud:setHint(matchUi.AimHint)
end
momentVisuals.onAim = function(info)
	if not info then
		if momentVisuals:isDeciding() then
			matchHud:setHint(matchUi.AimHint)
		end
		return
	end
	local value = if info.kind == "SHOT" then (if info.blocked then matchUi.AimShotBlocked else matchUi.AimShot)
		elseif info.kind == "MATE" then string.format(matchUi.AimPass, info.number or 0)
		elseif info.kind == "SHORT" then matchUi.AimShort
		else matchUi.AimSpace
	matchHud:setHint(value)
end
momentVisuals.onStrikeStart = function()
	matchHud:setHint(nil)
	matchHud:showStrike()
end
momentVisuals.onStrikeTimer = function(left)
	matchHud:setStrikeTimer(left)
end
momentVisuals.onReticle = function(position)
	matchHud:setReticle(position)
end
momentVisuals.onStrike = function(dirX, dirZ, length, hitX, hitY, aimTime)
	matchHud:hideStrike()
	matchHud:setHint(nil)
	if moment and moment.layout then
		MomentInput:FireServer(moment.episodeId, moment.layout.step, dirX, dirZ, length, hitX, hitY, aimTime)
	end
end
momentVisuals.onTimer = function(left)
	if matchHud.mode == "PLAY" then
		matchHud:setTimer(left)
	end
end

local SHOT_KEYS = { GOAL = "YOU_GOAL", SAVE = "YOU_SAVE", POST = "YOU_POST", MISS = "YOU_MISS" }
local PASS_KEYS = { INTERCEPTED = "PASS_FAIL", CLEARED = "CROSS_CLEARED", ASTRAY = "PASS_MISS", TOO_HARD = "PASS_HEAVY" }

-- A shot replay (yours or a teammate's finish) on the shot camera, then the studio.
local function playMatchShot(result, shooter, key: string, header: boolean?)
	momentVisuals:handOffShot(shooter, result.spot, header)
	visuals:reset(result.spot)
	visuals:setCameraEnabled(true)
	visuals:onShotReleased()
	if result.detail == "BLOCKED" then
		task.delay(math.max(0, (result.blockTime or 0) - 0.15), function()
			momentVisuals:block(result.blocker)
		end)
	end
	visuals:playShot(result, function()
		local goal = result.outcome == "GOAL"
		matchHud:setScore(result.score or matchHud.score, true)
		matchHud:banner(if result.detail == "BLOCKED" then "BLOCKED" else result.outcome)
		addLine(key, result.number, result.score)
		if goal then
			if moment then
				moment.involvement = if shooter == "ME" then "GOAL" else "ASSIST"
			end
			momentVisuals:celebrate(shooter)
		else
			addLine("CHANCE_LOST")
		end
		task.delay(if goal then CELEBRATION_TIME else AFTER_SHOT_TIME, function()
			backToStudio(result.score, result.state)
		end)
	end)
end

local function momentResult(result)
	if not moment or result.episodeId ~= moment.episodeId then
		return
	end
	if result.rejected then
		warn("[ShotClient] Server rejected the moment input:", result.reason)
		momentVisuals:resume()
		return
	end
	matchHud:hideStrike()
	matchHud:setHint(nil)
	if result.state then
		matchHud:setState(result.state)
	end
	if result.action == "TACKLE" then
		momentVisuals:tackle(result.tackler)
		matchHud:banner("TACKLED")
		addLine("YOU_TACKLED")
		addLine("CHANCE_LOST")
		task.delay(1.5, function()
			backToStudio(result.score, result.state)
		end)
	elseif result.action == "SHOT" then
		local key = if result.detail == "BLOCKED" then "YOU_BLOCKED" else SHOT_KEYS[result.outcome] or "YOU_MISS"
		playMatchShot(result, "ME", key)
	else
		momentVisuals:playPass(result, function()
			if result.detail ~= "GOOD" then
				matchHud:banner(result.detail)
				addLine(PASS_KEYS[result.detail] or "PASS_MISS", result.number)
				addLine("CHANCE_LOST")
				task.delay(1.2, function()
					backToStudio(result.score, result.state)
				end)
				return
			end
			addLine(if result.lofted then "CROSS_GOOD" else "PASS_GOOD", result.number)
			if result.finish then
				local finish = result.finish
				matchHud:banner(if result.lofted then "CROSS" else "PASS", 0.9)
				task.delay(if finish.header then 0.15 else 0.7, function()
					if not moment then
						return
					end
					local key
					if finish.header then
						key = if finish.outcome == "GOAL" then "HEADER_GOAL" elseif finish.outcome == "SAVE" then "HEADER_SAVE" else "HEADER_MISS"
					else
						key = if finish.outcome == "GOAL" then "ASSIST_GOAL" elseif finish.outcome == "SAVE" then "MATE_SAVE" else "MATE_MISS"
					end
					finish.score = result.score
					finish.state = result.state
					playMatchShot(finish, finish.receiver, key, finish.header)
				end)
			elseif result.continue then
				matchHud:banner("ONETWO", 1)
				addLine("ONETWO", result.number)
				task.delay(0.5, function()
					if moment then
						startStep(result.continue.layout)
					end
				end)
			else
				task.delay(1, function()
					backToStudio(result.score, result.state)
				end)
			end
		end)
	end
end

function handleResult(result)
	if typeof(result) ~= "table" then
		return
	end
	if result.kind == "MOMENT" then
		if inMatch then
			momentResult(result)
		end
		return
	end
	if not inTraining then
		return
	end
	if result.rejected then
		warn("[ShotClient] Server rejected the input:", result.reason)
		currentEpisode = nil
		input:setEnabled(false)
		task.delay(0.5, requestEpisode) -- the server resends the open episode or starts a new one
		return
	end
	if not currentEpisode or result.episodeId ~= currentEpisode.episodeId then
		return
	end
	currentEpisode = nil
	local pass = result.kind == "PASS"
	if not pass and result.mode == "TASK" and result.outcome == "GOAL" then
		bestSpeed = math.max(bestSpeed, result.speedKmh or 0)
	end

	local function onDecisive()
		if result.mode == "FOLLOWUP" and result.outcome == "GOAL" then
			passVisuals:celebrateGoal()
		end
		if result.mode == "TASK" then
			showProgress(result)
			if result.outcome == (if pass then "GOOD" else "GOAL") then
				hud:bumpGoals()
			end
		end
		if result.followUp then
			-- Good pass: no card, the receiver shoots next.
			hud:setTitle("PassReceived")
			task.delay(FOLLOW_UP_DELAY, function()
				if not currentEpisode and not waitingForEpisode then
					requestEpisode()
				end
			end)
			return
		end
		hud:setTitle(if pass then "PassAfter" else "AfterShot")
		task.delay(CARD_DELAY, function()
			if not currentEpisode and not waitingForEpisode then
				showOutcome(result)
			end
		end)
	end
	if pass then
		passVisuals:playPass(result, onDecisive)
	else
		visuals:playShot(result, onDecisive)
	end
end
EpisodeResult.OnClientEvent:Connect(function(result)
	handleResult(result)
end)

---------------------------------------------------------------- menus, training, match

-- Career menu: main menu -> club -> player -> training. It owns the camera while open.
local menu = CareerMenu.new(CareerRequest)
menu.onSettingsChanged = function(settings)
	visuals:setShakeEnabled(settings.shake)
	hud:setUiBoost(if settings.bigUi then 1.15 else 1)
	matchHud:setUiBoost(if settings.bigUi then 1.15 else 1)
end
menu.onStartTraining = function(career)
	passVisuals:setPasser(career.number, CareerConfig.upper(career.lastName))
	inTraining = true
	lastCompletedStage = nil
	bestSpeed = 0
	hud:setTrainingPanels(true)
	hud:setVisible(true)
	requestEpisode()
end

-- Match: the commentator's studio between your moments, the pitch only for them.
menu.onStartMatch = function(career, header)
	local home, away = CareerConfig.club(header.homeId), CareerConfig.club(header.awayId)
	if not (home and away) then
		menu:open()
		return
	end
	momentVisuals:setPlayer(career.number, CareerConfig.upper(career.lastName))
	inMatch = true
	moment = nil
	currentEpisode = nil
	waitingForEpisode = false
	hud:hideCard()
	hud:setVisible(false)
	setScene("MOMENT")
	momentVisuals:studio()
	matchHud:start(home, away, career.lastName, career.number, { stamina = header.stamina or 100, effort = header.effort or 2, focus = header.focus or "ATTACK" })
	MatchRequest:FireServer("NEXT")
end

matchHud.onEffort = function(effort)
	if inMatch then
		MatchRequest:FireServer("EFFORT", effort)
	end
end
matchHud.onFocus = function(focus)
	if inMatch then
		MatchRequest:FireServer("FOCUS", focus)
	end
end

local function leaveMatch()
	inMatch = false
	moment = nil
	input:setEnabled(false)
	hud:setVisible(false)
	setScene(nil)
	menu:open()
end
matchHud.onFinished = leaveMatch

MatchUpdate.OnClientEvent:Connect(function(update)
	if not inMatch or typeof(update) ~= "table" then
		return
	end
	if update.state then
		matchHud:setState(update.state)
	end
	matchHud:playEvents(update.events or {}, function()
		if not inMatch then
			return
		end
		if update.result then
			if update.career then
				menu:setCareer(update.career)
			end
			matchHud:showResult(update.result, update.career)
		elseif update.moment then
			matchHud:showPlay(function()
				startMoment(update)
			end)
		else
			MatchRequest:FireServer("NEXT")
		end
	end)
end)

-- After the pass task: put the drills away and go back to the career menu.
local function leaveTraining()
	inTraining = false
	currentEpisode = nil
	waitingForEpisode = false
	input:setEnabled(false)
	hint:hide()
	hud:hideCard()
	hud:setPowerZone(nil)
	hud:setVisible(false)
	setScene(nil)
	menu:open(true)
end

hud.onNext = function()
	if lastCompletedStage == "PASS" then
		leaveTraining()
	else
		continueWith("NEXT")
	end
end

-- Space / Enter / gamepad A press the card button.
UserInputService.InputBegan:Connect(function(inputObject, gameProcessed)
	if gameProcessed or not hud:isCardVisible() then
		return
	end
	local key = inputObject.KeyCode
	if key == Enum.KeyCode.Space or key == Enum.KeyCode.Return or key == Enum.KeyCode.ButtonA then
		hud:pressContinue()
	end
end)

local wasHolding = false
RunService.RenderStepped:Connect(function(dt)
	menu:update(dt) -- camera, blur and the player preview while the menu is open
	local pass = currentScene == "PASS"
	visuals:update(dt) -- keeper (and the camera while the shot drill has it)
	passVisuals:update(dt)
	momentVisuals:update(dt)
	input:update()
	if input.enabled then
		local guided = hint:isActive()
		local demoPower = hint:update(dt, input.holding, input.power, hud.scale, input.target)
		if pass then
			passVisuals:updateAiming(true, input.target, input.power, input.holding)
		else
			visuals:updateAiming(true, input.aimX, input.aimY, input.power, input.holding)
		end
		hud:setPower(if input.holding or not demoPower then (if input.holding then input.power else 0) else demoPower)
		local prefix = if pass then "Pass" else ""
		if guided then
			hud:setTitle(prefix .. (if input.holding then "TutorialHolding" else "TutorialReady"))
		else
			hud:setTitle(if pass then (if input.holding then "PassHolding" else "PassReady") else (if input.holding then "Holding" else "Ready"))
		end
	end
	-- The keeper gets set (hop + lower stance) while the player charges a shot.
	local holding = input.enabled and input.holding and not pass
	if holding ~= wasHolding then
		wasHolding = holding
		visuals:setCharging(holding)
	end
end)

print("[ShotClient] ready")
