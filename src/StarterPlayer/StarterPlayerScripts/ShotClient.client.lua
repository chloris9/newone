-- Client entry point: the career menus first (CareerMenu), then the shot and pass training, which
-- wires input, both drills' 3D visuals, the HUD and the finger hint to the server remotes. The
-- client sends only its input; the server decides outcomes and the training flow (shot: guided ->
-- task, pass: guided -> task). After the pass task the player goes back to the career menu.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local ShotConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ShotConfig"))
local CareerConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CareerConfig"))
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
local MomentPhysics = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MomentPhysics"))

local CARD_DELAY = 0.55 -- let the player see the ball hit the net before the card covers the goal
local FOLLOW_UP_DELAY = 0.75 -- after a good pass: the receiver controls it, then the shot camera
local MATCH_OUTCOME_TIME = 2.4 -- match: the commentator's line after your moment, before play goes on
local GOAL_CELEBRATION_TIME = 2.5 -- match: the scorer's celebration before the studio comes back

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
local currentScene = nil -- SHOT | PASS | FOLLOWUP (the shot after a good pass); nil in the menus
local SCENE_BLEND = 0.9 -- camera glide between scenes; input waits for it
local waitingForEpisode = false
local bestSpeed = 0 -- fastest goal in the current task attempt, for the completion menu
local inTraining = false
local inMatch = false
local matchHud = MatchHud.new()
local momentVisuals = MomentVisuals.new()
local matchUi = Commentary.ui()
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
-- shot drill's camera and ball), MOMENT (match moment: its own players and camera, the shot
-- drill's goal, keeper and shot replay), nil (menus: all put away). Returns whether the camera moves.
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
		momentVisuals:enter()
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

input.onShoot = function(a, b, power, action)
	local episode = currentEpisode
	if not episode then
		return
	end
	if episode.kind == "MOMENT" then
		if not momentVisuals:isDeciding() then
			return
		end
		input:setEnabled(false)
		hud:setPowerZone(nil)
		visuals:updateAiming(false, 0, 0.5, 0, false)
		momentVisuals:onReleased(action or "SHOT")
		matchHud:setHighBallVisible(false)
		matchHud:setPressure(nil)
		hud:setTitle(if action == "SHOT" then "Flying" else "PassFlying")
		if action == "SHOT" then
			visuals:onShotReleased()
		end
		SubmitEpisodeInput:FireServer(episode.episodeId, a, b, power, momentVisuals:decisionTime(), action)
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

local handleResult -- defined below; also plays a teammate's simulated shot (episode.auto)

EpisodeStarted.OnClientEvent:Connect(function(episode)
	if not (inTraining or inMatch) or typeof(episode) ~= "table" or (episode.kind ~= "SHOT" and episode.kind ~= "PASS") then
		return
	end
	waitingForEpisode = false
	currentEpisode = episode
	input:setEnabled(false)
	local pass = episode.kind == "PASS"
	local auto = episode.auto -- match: the teammate shoots after your pass, already resolved
	if inMatch and auto then
		-- The finish in the moment scene: a header is struck where he met the cross (the moment
		-- camera stays); a ground finish gets the shot camera behind him.
		local header = episode.header == true
		momentVisuals:beginFollowUp(episode.receiver, episode.spot, header)
		visuals:reset(episode.spot)
		if not header then
			visuals:setCameraEnabled(true)
		end
		hud:setVisible(true)
		hud:hideCard()
		hud:setPower(0)
		task.delay(if header then 0.1 else 1.2, function()
			if currentEpisode == episode then
				momentVisuals:followUpKick()
				visuals:onShotReleased()
				handleResult(auto)
			end
		end)
		return
	end
	local followUp = episode.mode == "FOLLOWUP" or auto ~= nil
	local moved = setScene(if pass then "PASS" elseif followUp then "FOLLOWUP" else "SHOT")
	if inMatch then
		hud:setVisible(true)
		matchHud:setPlaying(true)
	end
	if pass then
		passVisuals:reset(episode.layout)
		input:setMode("PASS", episode.layout.origin)
	elseif followUp then
		visuals:reset(episode.spot)
		passVisuals:beginFollowUp(episode.receiver, episode.spot, ShotVisuals.cameraPosition(episode.spot))
		input:setMode("SHOT")
		moved = true
	else
		visuals:reset(episode.spot) -- match: wherever the teammate's pass found you
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
	if auto then
		-- Nothing to aim: the teammate lines up and strikes, then the server's result plays.
		hud:setTitle("PassReceived")
		task.delay(1.2, function()
			if currentEpisode == episode then
				passVisuals:followUpKick()
				visuals:onShotReleased()
				handleResult(auto)
			end
		end)
		return
	end
	hud:setTitle(if pass then (if guide then "PassTutorialReady" else "PassReady") elseif guide then "TutorialReady" elseif followUp then "FollowUpReady" else "Ready")

	task.delay(if moved then math.max(SCENE_BLEND, ShotConfig.Input.ReadyDelay) else ShotConfig.Input.ReadyDelay, function()
		if currentEpisode == episode then
			input:setEnabled(true)
		end
	end)
end)

-- What the card says after each attempt, by the server's training status. In the pass stage the
-- card comes after the shot that follows a good pass, or straight after a failed pass.
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

-- Match: the commentator's line for what just happened (back in the studio), the new score, then
-- on with the match.
local function matchOutcome(result)
	local key
	if result.kind == "MOMENT" then
		local detail = result.detail
		if result.action == "TACKLE" then
			key = "YOU_TACKLED"
		elseif result.action == "SHOT" then
			key = if result.outcome == "GOAL" then "YOU_GOAL" elseif result.outcome == "SAVE" then "YOU_SAVE" elseif result.outcome == "POST" then "YOU_POST" else "YOU_MISS"
		else
			key = if detail == "INTERCEPTED" then "PASS_FAIL" elseif detail == "CLEARED" then "CROSS_CLEARED" else "PASS_MISS"
		end
	elseif result.kind == "PASS" then
		key = "PASS_FAIL"
	elseif result.mode == "AUTO" then
		if result.header then
			key = if result.outcome == "GOAL" then "HEADER_GOAL" elseif result.outcome == "SAVE" then "HEADER_SAVE" else "HEADER_MISS"
		else
			key = if result.outcome == "GOAL" then "ASSIST_GOAL" elseif result.outcome == "SAVE" then "MATE_SAVE" else "MATE_MISS"
		end
	else
		key = if result.outcome == "GOAL" then "YOU_GOAL" elseif result.outcome == "SAVE" then "YOU_SAVE" elseif result.outcome == "POST" then "YOU_POST" else "YOU_MISS"
	end
	hud:setVisible(false)
	matchHud:setPlaying(false)
	if result.score then
		matchHud:setScore(result.score, true)
	end
	if result.state then
		matchHud:setState(result.state)
	end
	matchHud:say(key, { n = result.number })
	task.delay(MATCH_OUTCOME_TIME, function()
		if inMatch and not currentEpisode then
			MatchRequest:FireServer("NEXT")
		end
	end)
end

-- Match moment result: the shot, the pass or cross, or the tackle, then the line in the studio.
local function momentResult(result)
	currentEpisode = nil
	input:setEnabled(false)
	visuals:updateAiming(false, 0, 0.5, 0, false)
	momentVisuals:updateAiming(false)
	matchHud:setPressure(nil)
	matchHud:setHighBallVisible(false)
	if result.action == "TACKLE" then
		momentVisuals:tackle(result.tackler)
		hud:setTitle("")
		task.delay(1.1, function()
			if inMatch and not currentEpisode then
				matchOutcome(result)
			end
		end)
	elseif result.action == "SHOT" then
		momentVisuals:onShotPlayed()
		visuals:playShot(result, function()
			local goal = result.outcome == "GOAL"
			if goal then
				momentVisuals:celebrate("ME")
			end
			task.delay(if goal then GOAL_CELEBRATION_TIME else CARD_DELAY + 0.5, function()
				if inMatch and not currentEpisode and not waitingForEpisode then
					matchOutcome(result)
				end
			end)
		end)
	else
		momentVisuals:playPass(result, function()
			if result.followUp then
				-- Received: no studio yet, the teammate finishes next.
				hud:setTitle(matchHud:say(if result.action == "CROSS" then "CROSS_GOOD" else "PASS_GOOD", { n = result.number }))
				waitingForEpisode = true
				task.delay(if result.header then 0.05 else FOLLOW_UP_DELAY, function()
					if inMatch and not currentEpisode then
						MatchRequest:FireServer("AUTO")
					end
				end)
				return
			end
			task.delay(0.9, function()
				if inMatch and not currentEpisode then
					matchOutcome(result)
				end
			end)
		end)
	end
end

-- The banner is done: onto the pitch. The decision clock (and the server's) starts after the intro.
local function startMoment(episode)
	if not inMatch or typeof(episode) ~= "table" or typeof(episode.layout) ~= "table" then
		return
	end
	local layout = episode.layout
	currentEpisode = episode
	waitingForEpisode = false
	input:setEnabled(false)
	input:setHighBall(false)
	setScene("MOMENT")
	visuals:setCameraEnabled(false)
	visuals:setSpot(MomentPhysics.shotSpot(layout))
	hud:hideCard()
	hud:setPower(0)
	hud:setPowerZone(nil)
	hud:setMode("SHOT", "MATCH", 1, "SHOT")
	hud:setTitle("")
	hud:setVisible(true)
	matchHud:setPlaying(true)
	matchHud:setHighBall(false)
	matchHud:setHighBallVisible(false)
	momentVisuals:begin(layout, function()
		if currentEpisode ~= episode then
			return
		end
		MatchRequest:FireServer("READY")
		input:setMode("MOMENT", layout.carrier)
		input:setEnabled(true)
		matchHud:setHighBallVisible(true)
	end)
end

function handleResult(result)
	if result.rejected then
		warn("[ShotClient] Server rejected the input:", result.reason)
		if inMatch then
			-- The moment is still open on the server: aim again.
			if currentEpisode then
				if currentEpisode.kind == "MOMENT" then
					momentVisuals:resume()
					matchHud:setHighBallVisible(true)
				end
				input:setEnabled(true)
			end
			return
		end
		currentEpisode = nil
		input:setEnabled(false)
		task.delay(0.5, requestEpisode) -- the server resends the open episode or starts a new one
		return
	end
	if not currentEpisode or result.episodeId ~= currentEpisode.episodeId then
		return
	end
	if result.kind == "MOMENT" then
		momentResult(result)
		return
	end
	local episodeInfo = currentEpisode
	currentEpisode = nil
	local pass = result.kind == "PASS"
	if not pass and result.mode == "TASK" and result.outcome == "GOAL" then
		bestSpeed = math.max(bestSpeed, result.speedKmh or 0)
	end

	local function onDecisive()
		if (result.mode == "FOLLOWUP" or result.mode == "AUTO") and result.outcome == "GOAL" then
			if inMatch then
				momentVisuals:celebrate(episodeInfo.receiver)
			else
				passVisuals:celebrateGoal()
			end
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
			if inMatch then
				matchHud:say("PASS_GOOD")
			end
			task.delay(FOLLOW_UP_DELAY, function()
				if not currentEpisode and not waitingForEpisode then
					if inMatch then
						MatchRequest:FireServer("AUTO")
					else
						requestEpisode()
					end
				end
			end)
			return
		end
		hud:setTitle(if pass then "PassAfter" else "AfterShot")
		-- A goal in a match: let the scorer's celebration play before the commentary takes over.
		local wait = if inMatch and result.mode == "AUTO" and result.outcome == "GOAL" then GOAL_CELEBRATION_TIME elseif inMatch then CARD_DELAY + 0.5 else CARD_DELAY
		task.delay(wait, function()
			if not currentEpisode and not waitingForEpisode then
				if inMatch then
					matchOutcome(result)
				else
					showOutcome(result)
				end
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

-- Match: between your moments the commentator's studio fills the screen (MatchHud); the pitch
-- (MomentVisuals over the shot drill's goal and keeper) only shows for your moments.
menu.onStartMatch = function(career, header)
	local home, away = CareerConfig.club(header.homeId), CareerConfig.club(header.awayId)
	if not (home and away) then
		menu:open()
		return
	end
	passVisuals:setPasser(career.number, CareerConfig.upper(career.lastName))
	momentVisuals:setPlayer(career.number, CareerConfig.upper(career.lastName))
	inMatch = true
	currentEpisode = nil
	waitingForEpisode = false
	hud:hideCard()
	hud:setTrainingPanels(false)
	hud:setVisible(false)
	setScene("MOMENT")
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
matchHud.onHighBall = function(on)
	input:setHighBall(on)
end

local function leaveMatch()
	inMatch = false
	currentEpisode = nil
	input:setEnabled(false)
	hint:hide()
	hud:setPowerZone(nil)
	hud:setVisible(false)
	hud:setTrainingPanels(true)
	setScene(nil)
	menu:open()
end
matchHud.onFinished = leaveMatch

MatchUpdate.OnClientEvent:Connect(function(update)
	if not inMatch or typeof(update) ~= "table" then
		return
	end
	hud:setVisible(false)
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
			local moment = update.moment
			matchHud:showMoment(moment, function()
				startMoment(moment.episode)
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
	visuals:update(dt) -- keeper (and the camera while the shot drill is active)
	passVisuals:update(dt)
	momentVisuals:update(dt)
	input:update()
	if currentScene == "MOMENT" then
		-- Match moment: shot (goal crosshair + power) or pass / cross (line on the grass).
		if input.enabled and not momentVisuals:isDeciding() then
			input:setEnabled(false) -- tackled
			visuals:updateAiming(false, 0, 0.5, 0, false)
			momentVisuals:updateAiming(false)
			matchHud:setHighBallVisible(false)
		end
		if input.enabled then
			local shooting = input.holding and input:isShooting()
			visuals:updateAiming(shooting, input.aimX, input.aimY, input.power, shooting)
			momentVisuals:updateAiming(true, input.action, input.target, input.holding)
			hud:setPower(if shooting then input.power elseif input.holding then math.clamp(input.power, 0, 1) else 0)
			local title
			if input.holding then
				title = if shooting then matchUi.MomentHolding elseif input.action == "CROSS" then matchUi.MomentCrossHolding else matchUi.MomentPassHolding
			else
				title = if input.highBall then matchUi.MomentHigh else matchUi.MomentReady
			end
			hud:setTitle(title)
		end
		matchHud:setPressure(momentVisuals:pressure())
	elseif input.enabled then
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
	local holding = input.enabled and input.holding and not pass and input:isShooting()
	if holding ~= wasHolding then
		wasHolding = holding
		visuals:setCharging(holding)
	end
end)

print("[ShotClient] ready")
