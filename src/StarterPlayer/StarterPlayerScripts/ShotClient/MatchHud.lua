-- Match screen: scoreboard (clubs, score, minute), the commentator's feed, the moment banner with
-- the SHOOT / PASS choice, and the full-time card. Same pixel-kit style and scale as the career
-- menus (UiKit). The entry script feeds it server updates; it never decides anything itself.

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local UiKit = require(script.Parent:WaitForChild("UiKit"))
local Commentary = require(script.Parent:WaitForChild("Commentary"))

local create, frame, text, corner, stroke, outline = UiKit.create, UiKit.frame, UiKit.text, UiKit.corner, UiKit.stroke, UiKit.outline
local NAVY, VIOLET, GLOW, LILAC, GOLD, LIME, RED = UiKit.NAVY, UiKit.VIOLET, UiKit.GLOW, UiKit.LILAC, UiKit.GOLD, UiKit.LIME, UiKit.RED
local CREAM, WHITE, INK = UiKit.CREAM, UiKit.WHITE, UiKit.INK
local FONT_BOLD, FONT_MEDIUM = UiKit.FONT_BOLD, UiKit.FONT_MEDIUM

local LAYOUT_SIZE = Vector2.new(920, 456)
local FEED_LINES = 3
local LINE_TIME = 1.9 -- seconds each commentary line gets before the next
local GOAL_KEYS = { OPP_GOAL = true, TEAM_GOAL = true, YOU_GOAL = true, ASSIST_GOAL = true }

local MatchHud = {}
MatchHud.__index = MatchHud

function MatchHud.new()
	local self = setmetatable({}, MatchHud)
	self.ui = Commentary.ui()
	self.onChoice = nil :: ((string) -> ())? -- "SHOOT" | "PASS"
	self.onFinished = nil :: (() -> ())? -- full-time card closed
	self.token = 0 -- bumps whenever a new sequence starts, so old timers stop
	self.minute = 0
	self.feed = {} :: { { label: TextLabel, minute: TextLabel } }

	local gui = UiKit.screenGui("MatchHud", 4)
	gui.Enabled = false
	self.gui = gui
	self.scaler = UiKit.scaler(gui, LAYOUT_SIZE)

	self:_buildScoreboard()
	self:_buildFeed()
	self:_buildMoment()
	self:_buildResult()
	return self
end

function MatchHud:_buildScoreboard()
	local holder = frame({ Name = "Scoreboard", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 8), Size = UDim2.fromOffset(470, 70), BackgroundTransparency = 1, Parent = self.gui })
	self.scaler:add(holder)
	local body = UiKit.panel({ Name = "Body", Size = UDim2.fromScale(1, 1), Parent = holder }, 12)
	self.sides = {}
	for i, anchor in { 0, 1 } do
		local side = frame({ Name = "Side" .. i, AnchorPoint = Vector2.new(anchor, 0), Position = UDim2.new(anchor, if i == 1 then 10 else -10, 0, 8), Size = UDim2.fromOffset(170, 54), BackgroundTransparency = 1, Parent = body })
		local crest = frame({ Name = "Crest", AnchorPoint = Vector2.new(anchor, 0.5), Position = UDim2.fromScale(anchor, 0.5), Size = UDim2.fromOffset(44, 44), BackgroundTransparency = 1, Parent = side })
		local name = text({
			Name = "ClubName",
			AnchorPoint = Vector2.new(anchor, 0),
			Position = UDim2.new(anchor, if i == 1 then 52 else -52, 0, 0),
			Size = UDim2.new(1, -56, 1, 0),
			Text = "",
			TextSize = 15,
			TextWrapped = true,
			TextXAlignment = if i == 1 then Enum.TextXAlignment.Left else Enum.TextXAlignment.Right,
			Parent = side,
		})
		outline(name, 1.5)
		self.sides[i] = { crest = crest, name = name }
	end
	local scoreText, scoreShadow = UiKit.bigText({ Name = "Score", Text = "0 : 0", TextSize = 34, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Center, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 4), Size = UDim2.fromOffset(120, 38), Parent = body }, 3, Vector2.new(0, 3))
	self.scoreText, self.scoreShadow = scoreText, scoreShadow
	self.scorePop = create("UIScale", { Parent = scoreText })
	local chip = frame({ Name = "Minute", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -5), Size = UDim2.fromOffset(58, 20), BackgroundColor3 = NAVY, Parent = body })
	corner(chip, 6)
	stroke(chip, GOLD, 1.5)
	self.minuteText = text({ Size = UDim2.fromScale(1, 1), Text = "0'", TextSize = 13, TextColor3 = GOLD, TextXAlignment = Enum.TextXAlignment.Center, Parent = chip })
end

function MatchHud:_buildFeed()
	local holder = frame({ Name = "Feed", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -14), Size = UDim2.fromOffset(640, 128), BackgroundTransparency = 1, Parent = self.gui })
	self.scaler:add(holder)
	self.feedHolder = holder
	local body = UiKit.panel({ Name = "Body", Size = UDim2.fromScale(1, 1), Parent = holder }, 12)
	local mic = text({ Position = UDim2.fromOffset(14, 6), Size = UDim2.fromOffset(300, 18), Text = "🎙  " .. self.ui.Commentator, TextSize = 12, FontFace = FONT_BOLD, TextColor3 = LILAC, Parent = body })
	outline(mic, 1)
	for i = 1, FEED_LINES do
		local y = 28 + (i - 1) * 32
		local minute = text({ Name = "Minute" .. i, Position = UDim2.fromOffset(14, y), Size = UDim2.fromOffset(40, 28), Text = "", TextSize = 14, TextColor3 = GOLD, Parent = body })
		outline(minute, 1)
		local label = text({ Name = "Line" .. i, Position = UDim2.fromOffset(56, y), Size = UDim2.new(1, -70, 0, 28), Text = "", TextSize = 16, FontFace = FONT_BOLD, TextWrapped = true, Parent = body })
		outline(label, 1.5)
		self.feed[i] = { label = label, minute = minute }
	end
	self.lines = {} :: { { minute: number, text: string, goal: boolean } }
end

function MatchHud:_buildMoment()
	local holder = frame({ Name = "Moment", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.46), Size = UDim2.fromOffset(460, 190), BackgroundTransparency = 1, Visible = false, Parent = self.gui })
	self.scaler:add(holder)
	self.momentHolder = holder
	local body = UiKit.panel({ Name = "Body", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), Parent = holder }, 14, GOLD)
	self.momentPop = create("UIScale", { Parent = body })
	UiKit.slashes(body, UDim2.new(1, -60, 0, 10), 20, GLOW)
	local title = UiKit.bigText({ Name = "Title", Text = self.ui.YourMoment, TextSize = 30, TextColor3 = GOLD, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(16, 10), Size = UDim2.new(1, -32, 0, 36), Parent = body }, 3, Vector2.new(2, 3))
	title.ZIndex = 2
	self.momentCount = text({ Name = "Count", Position = UDim2.fromOffset(16, 48), Size = UDim2.new(1, -32, 0, 18), Text = "", TextSize = 13, FontFace = FONT_BOLD, TextColor3 = LILAC, TextXAlignment = Enum.TextXAlignment.Center, Parent = body })
	outline(self.momentCount, 1)
	self.momentText = text({ Name = "Text", Position = UDim2.fromOffset(20, 68), Size = UDim2.new(1, -40, 0, 44), Text = "", TextSize = 16, FontFace = FONT_BOLD, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, Parent = body })
	outline(self.momentText, 1.5)
	self.shootButton = UiKit.button(body, { Name = "Shoot", Position = UDim2.fromOffset(20, 122), Size = UDim2.fromOffset(204, 52) }, "⚽  " .. self.ui.Shoot, function()
		self:_choose("SHOOT")
	end, "primary")
	self.passButton = UiKit.button(body, { Name = "Pass", Position = UDim2.fromOffset(236, 122), Size = UDim2.fromOffset(204, 52) }, "👟  " .. self.ui.Pass, function()
		self:_choose("PASS")
	end, "secondary")
end

function MatchHud:_buildResult()
	local root = frame({ Name = "Result", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, ZIndex = 10, Parent = self.gui })
	self.resultRoot = root
	frame({ Name = "Dim", Position = UDim2.fromOffset(-200, -120), Size = UDim2.new(1, 400, 1, 240), BackgroundColor3 = INK, BackgroundTransparency = 0.45, Parent = root })
	local holder = frame({ Name = "Holder", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(520, 380), BackgroundTransparency = 1, Parent = root })
	self.scaler:add(holder)
	local body = UiKit.panel({ Name = "Body", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), Parent = holder }, 16, GOLD)
	self.resultPop = create("UIScale", { Parent = body })
	UiKit.slashes(body, UDim2.fromOffset(16, 12), 22, GLOW)
	UiKit.slashes(body, UDim2.new(1, -64, 0, 12), 22, GLOW)
	local title, shadow = UiKit.bigText({ Name = "Title", Text = "", TextSize = 42, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(20, 18), Size = UDim2.new(1, -40, 0, 50), Parent = body }, 4, Vector2.new(0, 4))
	self.resultTitle, self.resultShadow = title, shadow
	self.resultScore = text({ Name = "Score", Position = UDim2.fromOffset(20, 74), Size = UDim2.new(1, -40, 0, 26), Text = "", TextSize = 20, TextXAlignment = Enum.TextXAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd, Parent = body })
	outline(self.resultScore, 2)

	self.statValues = {}
	for i, key in { "Goals", "Assists", "Rating" } do
		local box = frame({ Name = key, Position = UDim2.fromOffset(28 + (i - 1) * 158, 116), Size = UDim2.fromOffset(148, 92), BackgroundColor3 = NAVY, Parent = body })
		corner(box, 10)
		stroke(box, if key == "Rating" then GOLD else VIOLET, 2)
		local value = text({ Name = "Value", Position = UDim2.fromOffset(0, 8), Size = UDim2.new(1, 0, 0, 48), Text = "0", TextSize = 40, TextColor3 = if key == "Rating" then GOLD else CREAM, TextXAlignment = Enum.TextXAlignment.Center, Parent = box })
		outline(value, 2.5)
		local label = text({ Name = "Label", Position = UDim2.fromOffset(0, 62), Size = UDim2.new(1, 0, 0, 20), Text = self.ui[key], TextSize = 13, FontFace = FONT_BOLD, TextColor3 = LILAC, TextXAlignment = Enum.TextXAlignment.Center, Parent = box })
		outline(label, 1)
		self.statValues[key] = value
	end
	self.resultDetail = text({ Name = "Detail", Position = UDim2.fromOffset(20, 220), Size = UDim2.new(1, -40, 0, 20), Text = "", TextSize = 14, FontFace = FONT_MEDIUM, TextXAlignment = Enum.TextXAlignment.Center, Parent = body })
	outline(self.resultDetail, 1)

	local chips = frame({ Name = "Chips", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 252), Size = UDim2.fromOffset(460, 30), BackgroundTransparency = 1, Parent = body })
	create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder, Parent = chips })
	local _, xp = UiKit.chip(chips, { LayoutOrder = 1, Size = UDim2.fromOffset(0, 30) }, "", LIME)
	local _, level = UiKit.chip(chips, { LayoutOrder = 2, Size = UDim2.fromOffset(0, 30) }, "", GOLD)
	self.resultXp, self.resultLevel = xp, level

	self.resultButton = UiKit.button(body, { Name = "Continue", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 306), Size = UDim2.fromOffset(300, 52) }, self.ui.Continue, function()
		self:hide()
		if self.onFinished then
			self.onFinished()
		end
	end, "primary")
end

---------------------------------------------------------------- scoreboard and feed

function MatchHud:_setClub(index: number, club)
	local side = self.sides[index]
	for _, child in side.crest:GetChildren() do
		child:Destroy()
	end
	UiKit.crest(side.crest, { Size = UDim2.fromOffset(44, 44) }, club)
	side.name.Text = club.name
end

function MatchHud:setScore(score: { home: number, away: number }, pop: boolean?)
	local value = string.format("%d : %d", score.home, score.away)
	local changed = self.scoreText.Text ~= value
	self.score = score
	self.scoreText.Text = value
	self.scoreShadow.Text = value
	if changed and pop then
		UiKit.pop(self.scorePop, 1.5)
	end
end

function MatchHud:_setMinute(minute: number)
	self.minute = minute
	self.minuteText.Text = string.format("%d'", minute)
end

function MatchHud:_refreshFeed()
	local count = #self.lines
	for i = 1, FEED_LINES do
		local line = self.lines[count - FEED_LINES + i]
		local slot = self.feed[i]
		local newest = i == FEED_LINES
		slot.label.Text = if line then line.text else ""
		slot.minute.Text = if line then string.format("%d'", line.minute) else ""
		slot.label.TextColor3 = if line and line.goal then GOLD else CREAM
		slot.label.TextTransparency = if newest then 0 else 0.45
		slot.minute.TextTransparency = if newest then 0 else 0.45
	end
end

-- Adds a commentary line (and speaks it if a voice file is set for the key).
function MatchHud:say(key: string, params: { [string]: any }?, minute: number?)
	local filled = table.clone(self.names)
	for name, value in pairs(params or {}) do
		filled[name] = value
	end
	local score = self.score or { home = 0, away = 0 }
	filled.h, filled.a = score.home, score.away
	local line = Commentary.line(key, filled)
	if line == "" then
		return
	end
	table.insert(self.lines, { minute = minute or self.minute, text = line, goal = GOAL_KEYS[key] == true })
	self:_refreshFeed()
	local voice = Commentary.voice(key)
	if voice then
		local sound = create("Sound", { SoundId = voice, Parent = SoundService })
		sound.Ended:Once(function()
			sound:Destroy()
		end)
		sound:Play()
	end
end

---------------------------------------------------------------- match flow

-- header: { homeId, awayId, moments } with the clubs resolved by the caller.
function MatchHud:start(home, away, surname: string)
	self.token += 1
	self.names = { home = home.name, away = away.name, me = surname }
	self.lines = {}
	self:_setClub(1, home)
	self:_setClub(2, away)
	self:setScore({ home = 0, away = 0 })
	self:_setMinute(0)
	self:_refreshFeed()
	self.momentHolder.Visible = false
	self.resultRoot.Visible = false
	self.feedHolder.Visible = true
	self.gui.Enabled = true
end

-- Plays the simulated events one line at a time (minute ticking up to each), then calls done.
function MatchHud:playEvents(events: { any }, done: () -> ())
	self.token += 1
	local token = self.token
	self.feedHolder.Visible = true
	task.spawn(function()
		for _, event in events do
			-- Tick the clock up to the event's minute.
			local from = self.minute
			local steps = math.clamp(event.minute - from, 0, 12)
			for step = 1, steps do
				task.wait(0.05)
				if token ~= self.token then
					return
				end
				self:_setMinute(math.floor(from + (event.minute - from) * step / steps + 0.5))
			end
			self:_setMinute(event.minute)
			local key = event.key
			if key == "FULLTIME" then
				local score = event.score
				key = if score.home > score.away then "FULLTIME_WIN" elseif score.home == score.away then "FULLTIME_DRAW" else "FULLTIME_LOSS"
			end
			self:setScore(event.score, true)
			self:say(key, { n = event.number }, event.minute)
			task.wait(LINE_TIME)
			if token ~= self.token then
				return
			end
		end
		done()
	end)
end

-- The player's moment. CHOICE shows SHOOT / PASS; RECEIVE goes straight to the shot.
function MatchHud:showMoment(moment: { kind: string, minute: number, index: number, total: number, number: number })
	self.token += 1
	local token = self.token
	self:_setMinute(moment.minute)
	local key = if moment.kind == "CHOICE" then "MOMENT_CHOICE" else "MOMENT_RECEIVE"
	self:say(key, { n = moment.number }, moment.minute)
	self.momentCount.Text = string.format(self.ui.Moment, moment.index, moment.total)
	self.momentText.Text = self.lines[#self.lines].text
	local choice = moment.kind == "CHOICE"
	self.shootButton.button.Visible = choice
	self.passButton.button.Visible = choice
	self.chosen = false
	self.momentHolder.Visible = true
	UiKit.pop(self.momentPop, 0.6)
	if choice then
		self.shootButton:playShine()
	else
		task.delay(1.6, function()
			if token == self.token then
				self:_choose("SHOOT")
			end
		end)
	end
end

function MatchHud:_choose(choice: string)
	if self.chosen then
		return
	end
	self.chosen = true
	self.momentHolder.Visible = false
	if self.onChoice then
		self.onChoice(choice)
	end
end

-- While the player aims: only the scoreboard stays, the training HUD's power bar needs the room.
function MatchHud:setPlaying(playing: boolean)
	self.feedHolder.Visible = not playing
	if playing then
		self.momentHolder.Visible = false
	end
end

function MatchHud:showResult(result, career)
	self.token += 1
	local ui = self.ui
	local title = if result.outcome == "WIN" then ui.Win elseif result.outcome == "DRAW" then ui.Draw else ui.Loss
	self.resultTitle.Text = title
	self.resultShadow.Text = title
	self.resultTitle.TextColor3 = if result.outcome == "WIN" then GOLD elseif result.outcome == "DRAW" then CREAM else RED
	self.resultScore.Text = string.format("%s  %d : %d  %s", self.names.home, result.home, result.away, self.names.away)
	self.statValues.Goals.Text = tostring(result.goals)
	self.statValues.Assists.Text = tostring(result.assists)
	self.statValues.Rating.Text = string.format("%.1f", result.rating)
	self.resultDetail.Text = string.format(ui.Shots, result.shots, result.goodPasses, result.passes)
	self.resultXp.Text = string.format(ui.Xp, result.xp)
	self.resultLevel.Text = string.format(ui.Level, if career then career.level else 1)
	self.momentHolder.Visible = false
	self.resultRoot.Visible = true
	UiKit.pop(self.resultPop, 0.6)
	self.resultButton:playShine()
end

function MatchHud:hide()
	self.token += 1
	self.gui.Enabled = false
end

function MatchHud:setUiBoost(boost: number)
	self.scaler:setBoost(boost)
end

return MatchHud
