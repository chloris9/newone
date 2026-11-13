-- Match screen. Between your moments the whole screen is the commentator's studio: scoreboard,
-- the commentator's live feed, the match timeline, and your player's card with the stamina bar
-- and the two tactics (effort: 1-3 hearts, focus: attack / defense). The 3D pitch only shows
-- during your moments, with the pressure bar and the high-ball switch on top. Same pixel-kit
-- style and scale as the career menus (UiKit). It never decides anything itself.

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local UiKit = require(script.Parent:WaitForChild("UiKit"))
local Commentary = require(script.Parent:WaitForChild("Commentary"))

local create, frame, text, corner, stroke, outline = UiKit.create, UiKit.frame, UiKit.text, UiKit.corner, UiKit.stroke, UiKit.outline
local NAVY, VIOLET, GLOW, LILAC, GOLD, LIME, RED = UiKit.NAVY, UiKit.VIOLET, UiKit.GLOW, UiKit.LILAC, UiKit.GOLD, UiKit.LIME, UiKit.RED
local CREAM, WHITE, INK, ORANGE = UiKit.CREAM, UiKit.WHITE, UiKit.INK, UiKit.ORANGE
local FONT_BOLD, FONT_MEDIUM, FONT_HEAVY = UiKit.FONT_BOLD, UiKit.FONT_MEDIUM, UiKit.FONT_HEAVY

local LAYOUT_SIZE = Vector2.new(920, 456)
local HISTORY_LINES = 4
local LINE_TIME = 2.1 -- seconds each commentary line gets before the next
local TYPE_TIME = 0.35 -- the newest line types itself in
local FADE_TIME = 0.45 -- studio <-> pitch
local MOMENT_BANNER_TIME = 1.7
local TACTIC_HOLD = 1.5 -- after a tap, the server's echo of the old tactic doesn't undo it
local GOAL_KEYS = { OPP_GOAL = true, TEAM_GOAL = true, YOU_GOAL = true, ASSIST_GOAL = true, HEADER_GOAL = true }

local MatchHud = {}
MatchHud.__index = MatchHud

function MatchHud.new()
	local self = setmetatable({}, MatchHud)
	self.ui = Commentary.ui()
	self.onEffort = nil :: ((number) -> ())?
	self.onFocus = nil :: ((string) -> ())?
	self.onHighBall = nil :: ((boolean) -> ())?
	self.onFinished = nil :: (() -> ())? -- full-time card closed
	self.token = 0 -- bumps whenever a new sequence starts, so old timers stop
	self.minute = 0
	self.lines = {} :: { { minute: number, text: string, goal: boolean } }
	self.effort = 2
	self.focus = "ATTACK"
	self.stamina = 100
	self.tacticAt = -math.huge
	self.highBall = false
	self.names = { home = "", away = "", me = "" }

	local gui = UiKit.screenGui("MatchHud", 4)
	gui.Enabled = false
	self.gui = gui
	self.scaler = UiKit.scaler(gui, LAYOUT_SIZE)

	self:_buildBackdrop()
	self:_buildScoreboard()
	self:_buildStudio()
	self:_buildPlayOverlay()
	self:_buildMoment()
	self:_buildResult()
	return self
end

---------------------------------------------------------------- building

-- Full-screen studio background: deep violet with a faint pitch drawn on it.
function MatchHud:_buildBackdrop()
	local group = create("CanvasGroup", { Name = "Backdrop", Position = UDim2.fromOffset(0, 0), Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, BorderSizePixel = 0, ZIndex = 0, Parent = self.gui })
	create("UIGradient", { Color = ColorSequence.new(UiKit.PANEL_TOP, NAVY), Rotation = 90, Parent = group })
	self.backdrop = group
	local pitch = frame({ Name = "Pitch", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.56), Size = UDim2.fromScale(0.92, 0.7), BackgroundTransparency = 1, Parent = group })
	stroke(pitch, GLOW, 2, 0.8)
	frame({ Name = "Halfway", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0), Size = UDim2.new(0, 2, 1, 0), BackgroundColor3 = GLOW, BackgroundTransparency = 0.8, Parent = pitch })
	local circle = frame({ Name = "Circle", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.22, 0.22), BackgroundTransparency = 1, Parent = pitch })
	create("UIAspectRatioConstraint", { AspectRatio = 1, Parent = circle })
	corner(circle, 999)
	stroke(circle, GLOW, 2, 0.8)
	for i, anchor in { 0, 1 } do
		local box = frame({ Name = "Box" .. i, AnchorPoint = Vector2.new(anchor, 0.5), Position = UDim2.fromScale(anchor, 0.5), Size = UDim2.fromScale(0.14, 0.5), BackgroundTransparency = 1, Parent = pitch })
		stroke(box, GLOW, 2, 0.8)
	end
end

function MatchHud:_buildScoreboard()
	local holder = frame({ Name = "Scoreboard", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 8), Size = UDim2.fromOffset(470, 70), BackgroundTransparency = 1, ZIndex = 2, Parent = self.gui })
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

-- Horizontal bar: returns the fill frame and the label on it.
local function bar(parent: Instance, props: { [string]: any }, color: Color3): (Frame, Frame, TextLabel)
	local track = frame(props)
	track.BackgroundColor3 = INK
	corner(track, 8)
	stroke(track, INK, 2)
	local fill = frame({ Name = "Fill", Size = UDim2.fromScale(1, 1), BackgroundColor3 = color, Parent = track })
	corner(fill, 8)
	create("UIGradient", { Color = ColorSequence.new(WHITE, Color3.fromRGB(200, 200, 200)), Rotation = 90, Parent = fill })
	local label = text({ Name = "Label", Size = UDim2.fromScale(1, 1), Text = "", TextSize = 13, TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 3, Parent = track })
	outline(label, 1.5)
	track.Parent = parent
	return track, fill, label
end

function MatchHud:_buildStudio()
	local ui = self.ui
	-- Anchored to the bottom so on short phone screens it never runs into the scoreboard.
	local holder = frame({ Name = "Studio", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -8), Size = UDim2.fromOffset(900, 348), BackgroundTransparency = 1, ZIndex = 2, Parent = self.gui })
	self.scaler:add(holder)
	self.studio = holder

	-- Commentator: who is talking, the newest line big, the last few above it.
	local feed = UiKit.panel({ Name = "Commentator", Size = UDim2.fromOffset(580, 300), Parent = holder }, 14)
	local mic = frame({ Name = "Mic", Position = UDim2.fromOffset(14, 12), Size = UDim2.fromOffset(46, 46), BackgroundColor3 = VIOLET, Parent = feed })
	corner(mic, 999)
	stroke(mic, GOLD, 2)
	text({ Size = UDim2.fromScale(1, 1), Text = "🎙", TextSize = 24, TextXAlignment = Enum.TextXAlignment.Center, Parent = mic })
	local who = text({ Name = "Who", Position = UDim2.fromOffset(70, 12), Size = UDim2.fromOffset(300, 22), Text = ui.Commentator, TextSize = 16, FontFace = FONT_HEAVY, TextColor3 = LILAC, Parent = feed })
	outline(who, 1.5)
	local live = frame({ Name = "Live", Position = UDim2.fromOffset(70, 38), Size = UDim2.fromOffset(52, 18), BackgroundColor3 = RED, Parent = feed })
	corner(live, 5)
	self.liveDot = text({ Size = UDim2.fromScale(1, 1), Text = "● " .. ui.Live, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Center, Parent = live })
	UiKit.slashes(feed, UDim2.new(1, -60, 0, 12), 20, GLOW)

	self.history = {}
	for i = 1, HISTORY_LINES do
		local y = 66 + (i - 1) * 26
		local minute = text({ Name = "Minute" .. i, Position = UDim2.fromOffset(16, y), Size = UDim2.fromOffset(40, 24), Text = "", TextSize = 13, TextColor3 = GOLD, Parent = feed })
		local label = text({ Name = "Line" .. i, Position = UDim2.fromOffset(58, y), Size = UDim2.new(1, -74, 0, 24), Text = "", TextSize = 14, FontFace = FONT_MEDIUM, TextTruncate = Enum.TextTruncate.AtEnd, Parent = feed })
		self.history[i] = { label = label, minute = minute }
	end
	local current = frame({ Name = "Current", Position = UDim2.fromOffset(12, 176), Size = UDim2.new(1, -24, 0, 112), BackgroundColor3 = NAVY, Parent = feed })
	corner(current, 10)
	stroke(current, GLOW, 2, 0.3)
	self.currentMinute = text({ Name = "Minute", Position = UDim2.fromOffset(12, 8), Size = UDim2.fromOffset(60, 30), Text = "", TextSize = 24, FontFace = FONT_HEAVY, TextColor3 = GOLD, Parent = current })
	outline(self.currentMinute, 2)
	self.currentText = text({ Name = "Text", Position = UDim2.fromOffset(78, 6), Size = UDim2.new(1, -90, 1, -12), Text = "", TextSize = 22, FontFace = FONT_BOLD, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Center, Parent = current })
	outline(self.currentText, 2)
	self.currentPop = create("UIScale", { Parent = current })

	-- Your player: stamina and the two tactics.
	local card = UiKit.panel({ Name = "Player", Position = UDim2.fromOffset(596, 0), Size = UDim2.fromOffset(304, 300), Parent = holder }, 14, GOLD)
	local title = text({ Name = "Title", Position = UDim2.fromOffset(14, 10), Size = UDim2.new(1, -28, 0, 16), Text = ui.YourPlayer, TextSize = 12, FontFace = FONT_BOLD, TextColor3 = LILAC, Parent = card })
	outline(title, 1)
	self.playerName = text({ Name = "Name", Position = UDim2.fromOffset(14, 26), Size = UDim2.new(1, -28, 0, 26), Text = "", TextSize = 22, FontFace = FONT_HEAVY, TextColor3 = GOLD, TextTruncate = Enum.TextTruncate.AtEnd, Parent = card })
	outline(self.playerName, 2)

	local staminaLabel = text({ Position = UDim2.fromOffset(14, 58), Size = UDim2.new(1, -28, 0, 16), Text = "⚡ " .. ui.Stamina, TextSize = 12, FontFace = FONT_BOLD, Parent = card })
	outline(staminaLabel, 1)
	local _, fill, label = bar(card, { Name = "Stamina", Position = UDim2.fromOffset(14, 76), Size = UDim2.new(1, -28, 0, 24) }, LIME)
	self.staminaFill, self.staminaLabel = fill, label

	local effortLabel = text({ Position = UDim2.fromOffset(14, 110), Size = UDim2.new(1, -28, 0, 16), Text = ui.Effort, TextSize = 12, FontFace = FONT_BOLD, Parent = card })
	outline(effortLabel, 1)
	self.effortButtons = {}
	for n = 1, 3 do
		local button = UiKit.button(card, { Name = "Effort" .. n, Position = UDim2.fromOffset(14 + (n - 1) * 94, 128), Size = UDim2.fromOffset(86, 44), TextSize = 17 }, string.rep("❤", n), function()
			self:_pickEffort(n)
		end, "secondary")
		self.effortButtons[n] = self:_selectable(button)
	end
	local effortHint = text({ Position = UDim2.fromOffset(14, 174), Size = UDim2.new(1, -28, 0, 28), Text = ui.EffortHint, TextSize = 11, FontFace = FONT_MEDIUM, TextColor3 = LILAC, TextWrapped = true, Parent = card })
	outline(effortHint, 1)

	local focusLabel = text({ Position = UDim2.fromOffset(14, 204), Size = UDim2.new(1, -28, 0, 16), Text = ui.Focus, TextSize = 12, FontFace = FONT_BOLD, Parent = card })
	outline(focusLabel, 1)
	self.focusButtons = {}
	for i, focus in { "ATTACK", "DEFENSE" } do
		local caption = if focus == "ATTACK" then "⚔ " .. ui.Attack else "🛡 " .. ui.Defense
		local button = UiKit.button(card, { Name = focus, Position = UDim2.fromOffset(14 + (i - 1) * 142, 222), Size = UDim2.fromOffset(134, 44), TextSize = 16 }, caption, function()
			self:_pickFocus(focus)
		end, "secondary")
		self.focusButtons[focus] = self:_selectable(button)
	end
	local focusHint = text({ Position = UDim2.fromOffset(14, 268), Size = UDim2.new(1, -28, 0, 28), Text = ui.FocusHint, TextSize = 11, FontFace = FONT_MEDIUM, TextColor3 = LILAC, TextWrapped = true, Parent = card })
	outline(focusHint, 1)

	-- Timeline: 0' to 90', half-time mark, a gold dot per goal.
	local track, timeFill = bar(holder, { Name = "Timeline", Position = UDim2.fromOffset(0, 312), Size = UDim2.new(1, 0, 0, 16) }, GLOW)
	self.timeline, self.timeFill = track, timeFill
	frame({ Name = "Half", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(0, 3, 1, 8), BackgroundColor3 = CREAM, ZIndex = 4, Parent = track })
	for i, label in { "0'", "45'", "90'" } do
		local t = text({ AnchorPoint = Vector2.new((i - 1) / 2, 0), Position = UDim2.new((i - 1) / 2, 0, 1, 4), Size = UDim2.fromOffset(40, 16), Text = label, TextSize = 12, TextColor3 = LILAC, TextXAlignment = if i == 1 then Enum.TextXAlignment.Left elseif i == 3 then Enum.TextXAlignment.Right else Enum.TextXAlignment.Center, Parent = track })
		outline(t, 1)
	end
end

-- A tactic button with a gold frame and a check when picked.
function MatchHud:_selectable(button)
	local ring = frame({ Name = "Picked", Position = UDim2.fromOffset(-4, -4), Size = UDim2.new(1, 8, 1, 8), BackgroundTransparency = 1, Visible = false, ZIndex = 5, Parent = button.button })
	corner(ring, 12)
	stroke(ring, GOLD, 3)
	return { button = button, ring = ring }
end

function MatchHud:_buildPlayOverlay()
	local ui = self.ui
	local holder = frame({ Name = "Play", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 84), Size = UDim2.fromOffset(380, 56), BackgroundTransparency = 1, Visible = false, ZIndex = 2, Parent = self.gui })
	self.scaler:add(holder)
	self.playHolder = holder
	local warn = text({ Name = "PressureLabel", Size = UDim2.new(1, 0, 0, 18), Text = "⚠ " .. ui.Pressure, TextSize = 13, FontFace = FONT_HEAVY, TextColor3 = UiKit.RED_LIGHT, TextXAlignment = Enum.TextXAlignment.Center, Parent = holder })
	outline(warn, 1.5)
	self.pressureLabel = warn
	local track, fill = bar(holder, { Name = "Pressure", Position = UDim2.fromOffset(0, 20), Size = UDim2.new(1, 0, 0, 14) }, ORANGE)
	self.pressureTrack, self.pressureFill = track, fill
	local _, sFill, sLabel = bar(holder, { Name = "Stamina", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 38), Size = UDim2.new(0.6, 0, 0, 14) }, LIME)
	self.playStaminaFill, self.playStaminaLabel = sFill, sLabel
	sLabel.TextSize = 10

	-- High ball switch, right edge: on = your next pass is lofted (a cross).
	local side = frame({ Name = "HighBall", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0.55, 0), Size = UDim2.fromOffset(150, 60), BackgroundTransparency = 1, Visible = false, ZIndex = 3, Parent = self.gui })
	self.scaler:add(side)
	self.highHolder = side
	self.highButton = UiKit.button(side, { Name = "Toggle", Size = UDim2.fromOffset(150, 60), TextSize = 18 }, "⤴ " .. ui.HighBall, function()
		self:setHighBall(not self.highBall)
		if self.onHighBall then
			self.onHighBall(self.highBall)
		end
	end, "secondary")
	self.highSelect = self:_selectable(self.highButton)
end

function MatchHud:_buildMoment()
	local holder = frame({ Name = "Moment", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(500, 150), BackgroundTransparency = 1, Visible = false, ZIndex = 8, Parent = self.gui })
	self.scaler:add(holder)
	self.momentHolder = holder
	local body = UiKit.panel({ Name = "Body", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), Parent = holder }, 14, GOLD)
	self.momentPop = create("UIScale", { Parent = body })
	UiKit.slashes(body, UDim2.new(1, -60, 0, 10), 20, GLOW)
	UiKit.slashes(body, UDim2.fromOffset(14, 10), 20, GLOW)
	local title = UiKit.bigText({ Name = "Title", Text = self.ui.YourMoment, TextSize = 34, TextColor3 = GOLD, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(16, 10), Size = UDim2.new(1, -32, 0, 40), Parent = body }, 3, Vector2.new(2, 3))
	title.ZIndex = 2
	self.momentCount = text({ Name = "Count", Position = UDim2.fromOffset(16, 54), Size = UDim2.new(1, -32, 0, 18), Text = "", TextSize = 13, FontFace = FONT_BOLD, TextColor3 = LILAC, TextXAlignment = Enum.TextXAlignment.Center, Parent = body })
	outline(self.momentCount, 1)
	self.momentText = text({ Name = "Text", Position = UDim2.fromOffset(20, 76), Size = UDim2.new(1, -40, 0, 60), Text = "", TextSize = 18, FontFace = FONT_BOLD, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, Parent = body })
	outline(self.momentText, 1.5)
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

---------------------------------------------------------------- scoreboard, feed, tactics

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
	self.timeFill.Size = UDim2.fromScale(math.clamp(minute / 90, 0, 1), 1)
end

function MatchHud:_goalMark(minute: number, ours: boolean)
	local dot = frame({ Name = "Goal", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(math.clamp(minute / 90, 0, 1), 0.5), Size = UDim2.fromOffset(14, 14), BackgroundColor3 = if ours then GOLD else RED, ZIndex = 5, Parent = self.timeline })
	dot.Name = "GoalMark"
	corner(dot, 999)
	stroke(dot, INK, 2)
end

function MatchHud:_refreshFeed(typeIn: boolean)
	local count = #self.lines
	local newest = self.lines[count]
	self.currentMinute.Text = if newest then string.format("%d'", newest.minute) else ""
	self.currentText.Text = if newest then newest.text else ""
	self.currentText.TextColor3 = if newest and newest.goal then GOLD else WHITE
	if typeIn and newest then
		self.currentText.MaxVisibleGraphemes = 0
		local length = utf8.len(newest.text) or #newest.text
		TweenService:Create(self.currentText, TweenInfo.new(TYPE_TIME, Enum.EasingStyle.Linear), { MaxVisibleGraphemes = length }):Play()
		UiKit.pop(self.currentPop, if newest.goal then 1.12 else 1.03)
	else
		self.currentText.MaxVisibleGraphemes = -1
	end
	for i = 1, HISTORY_LINES do
		local line = self.lines[count - HISTORY_LINES - 1 + i]
		local slot = self.history[i]
		slot.label.Text = if line then line.text else ""
		slot.minute.Text = if line then string.format("%d'", line.minute) else ""
		slot.label.TextColor3 = if line and line.goal then GOLD else CREAM
		local fade = 0.15 + 0.6 * (HISTORY_LINES - i) / HISTORY_LINES
		slot.label.TextTransparency = fade
		slot.minute.TextTransparency = fade
	end
end

-- Adds a commentary line (and speaks it if a voice file is set for the key). Returns the text.
function MatchHud:say(key: string, params: { [string]: any }?, minute: number?): string
	local filled = table.clone(self.names)
	for name, value in pairs(params or {}) do
		filled[name] = value
	end
	local score = self.score or { home = 0, away = 0 }
	filled.h, filled.a = score.home, score.away
	local line = Commentary.line(key, filled)
	if line == "" then
		return ""
	end
	table.insert(self.lines, { minute = minute or self.minute, text = line, goal = GOAL_KEYS[key] == true })
	self:_refreshFeed(true)
	if GOAL_KEYS[key] then
		self:_goalMark(minute or self.minute, key ~= "OPP_GOAL")
	end
	local voice = Commentary.voice(key)
	if voice then
		local sound = create("Sound", { SoundId = voice, Parent = SoundService })
		sound.Ended:Once(function()
			sound:Destroy()
		end)
		sound:Play()
	end
	return line
end

function MatchHud:_showTactics()
	for n, entry in self.effortButtons do
		entry.ring.Visible = n == self.effort
	end
	for focus, entry in self.focusButtons do
		entry.ring.Visible = focus == self.focus
	end
end

function MatchHud:_pickEffort(n: number)
	if n == self.effort then
		return
	end
	self.effort = n
	self.tacticAt = os.clock()
	self:_showTactics()
	self:say("TACTIC_EFFORT_" .. n)
	if self.onEffort then
		self.onEffort(n)
	end
end

function MatchHud:_pickFocus(focus: string)
	if focus == self.focus then
		return
	end
	self.focus = focus
	self.tacticAt = os.clock()
	self:_showTactics()
	self:say(if focus == "ATTACK" then "TACTIC_ATTACK" else "TACTIC_DEFENSE")
	if self.onFocus then
		self.onFocus(focus)
	end
end

local function staminaColor(stamina: number): Color3
	return if stamina > 50 then LIME elseif stamina > 20 then GOLD else RED
end

-- Server state: { stamina, effort, focus }.
function MatchHud:setState(state)
	if typeof(state) ~= "table" then
		return
	end
	local stamina = math.clamp(tonumber(state.stamina) or self.stamina, 0, 100)
	local wasEmpty = self.stamina <= 0
	self.stamina = stamina
	for _, pair in { { self.staminaFill, self.staminaLabel }, { self.playStaminaFill, self.playStaminaLabel } } do
		TweenService:Create(pair[1], TweenInfo.new(0.4), { Size = UDim2.fromScale(math.max(stamina, 0.001) / 100, 1), BackgroundColor3 = staminaColor(stamina) }):Play()
		pair[2].Text = string.format("⚡ %d%%", math.floor(stamina + 0.5))
	end
	if os.clock() - self.tacticAt > TACTIC_HOLD then
		self.effort = state.effort or self.effort
		self.focus = state.focus or self.focus
		self:_showTactics()
	end
	-- Out of stamina: full effort is over, drop to one heart.
	if stamina <= 0 and not wasEmpty then
		self:say("STAMINA_EMPTY")
		if self.effort > 1 then
			self.effort = 1
			self.tacticAt = os.clock()
			self:_showTactics()
			if self.onEffort then
				self.onEffort(1)
			end
		end
	end
end

---------------------------------------------------------------- match flow

-- clubs resolved by the caller; state: the server's opening { stamina, effort, focus }.
function MatchHud:start(home, away, surname: string, number: number?, state)
	self.token += 1
	self.names = { home = home.name, away = away.name, me = surname }
	self.lines = {}
	self:_setClub(1, home)
	self:_setClub(2, away)
	for _, child in self.timeline:GetChildren() do
		if child.Name == "GoalMark" then
			child:Destroy()
		end
	end
	self.playerName.Text = if number then string.format("#%d  %s", number, string.upper(surname)) else string.upper(surname)
	self.stamina = 100
	self.tacticAt = -math.huge
	self:setState(state or { stamina = 100, effort = 2, focus = "ATTACK" })
	self:setScore({ home = 0, away = 0 })
	self:_setMinute(0)
	self:_refreshFeed(false)
	self:setHighBall(false)
	self.momentHolder.Visible = false
	self.resultRoot.Visible = false
	self:setPlaying(false, true)
	self.gui.Enabled = true
end

-- Plays the simulated events one line at a time (minute ticking up to each), then calls done.
function MatchHud:playEvents(events: { any }, done: () -> ())
	self.token += 1
	local token = self.token
	task.spawn(function()
		for _, event in events do
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
			task.wait(if GOAL_KEYS[key] then LINE_TIME + 0.6 else LINE_TIME)
			if token ~= self.token then
				return
			end
		end
		done()
	end)
end

-- Your moment: the banner over the studio, then go() switches to the pitch.
function MatchHud:showMoment(moment: { kind: string, minute: number, index: number, number: number }, go: () -> ())
	self.token += 1
	local token = self.token
	self:_setMinute(moment.minute)
	local key = if moment.kind == "RECEIVE" then "MOMENT_RECEIVE" else "MOMENT_ONBALL"
	local line = self:say(key, { n = moment.number }, moment.minute)
	self.momentCount.Text = string.format(self.ui.Moment, moment.index)
	self.momentText.Text = line
	self.momentHolder.Visible = true
	UiKit.pop(self.momentPop, 0.6)
	task.delay(MOMENT_BANNER_TIME, function()
		if token == self.token then
			self.momentHolder.Visible = false
			go()
		end
	end)
end

-- playing: the pitch is on screen (your moment); otherwise the studio covers it.
function MatchHud:setPlaying(playing: boolean, instant: boolean?)
	self.playing = playing
	self.studio.Visible = not playing
	self.playHolder.Visible = playing
	self.highHolder.Visible = playing
	if playing then
		self.momentHolder.Visible = false
		self:setPressure(nil)
	end
	local goal = if playing then 1 else 0
	if instant then
		self.backdrop.GroupTransparency = goal
		self.backdrop.Visible = not playing
		return
	end
	self.backdrop.Visible = true
	local tween = TweenService:Create(self.backdrop, TweenInfo.new(FADE_TIME, Enum.EasingStyle.Quad), { GroupTransparency = goal })
	tween.Completed:Once(function()
		if self.playing == playing then
			self.backdrop.Visible = not playing
		end
	end)
	tween:Play()
end

-- Time left before the tackle, 1 = plenty, 0 = now; nil hides the bar.
function MatchHud:setPressure(left: number?)
	self.pressureTrack.Visible = left ~= nil
	self.pressureLabel.Visible = left ~= nil
	if left then
		local k = math.clamp(left, 0, 1)
		self.pressureFill.Size = UDim2.fromScale(k, 1)
		self.pressureFill.BackgroundColor3 = if k > 0.5 then ORANGE else RED
		self.pressureLabel.TextTransparency = if k < 0.3 then 0.5 + 0.5 * math.sin(os.clock() * 18) else 0
	end
end

function MatchHud:setHighBall(on: boolean)
	self.highBall = on
	self.highSelect.ring.Visible = on
end

-- The high-ball switch only makes sense while you can still play the ball.
function MatchHud:setHighBallVisible(visible: boolean)
	self.highHolder.Visible = visible and self.playing == true
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
