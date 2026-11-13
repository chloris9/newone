-- Match screens (one ScreenGui, laid out in screen fractions so it fills any landscape screen):
--   STUDIO, between your moments: broadcast scoreboard, the commentator's feed (bars that fill an
--     empty board one by one, a new board for each chance), your player card with energy, the
--     work-rate and focus cards (each opens a chooser), the moments so far, and the big PLAY button
--     when your moment comes.
--   PLAY, your moment on the pitch: compact scoreboard, the time left before the tackle, the hint,
--     the strike screen (stopwatch, how the hit point works, the reticle) and result banners.
--   The full-time card.
-- It never decides anything: the entry script feeds it server updates and wires its callbacks.

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local UiKit = require(script.Parent:WaitForChild("UiKit"))
local Commentary = require(script.Parent:WaitForChild("Commentary"))

local create, frame, text, corner, stroke, outline = UiKit.create, UiKit.frame, UiKit.text, UiKit.corner, UiKit.stroke, UiKit.outline
local rgb = UiKit.rgb
local NAVY, VIOLET, LILAC, GOLD, LIME, RED = UiKit.NAVY, UiKit.VIOLET, UiKit.LILAC, UiKit.GOLD, UiKit.LIME, UiKit.RED
local CREAM, WHITE, INK, ORANGE = UiKit.CREAM, UiKit.WHITE, UiKit.INK, UiKit.ORANGE
local PANEL_TOP, PANEL_BOTTOM = UiKit.PANEL_TOP, UiKit.PANEL_BOTTOM
local FONT_HEAVY, FONT_BOLD, FONT_MEDIUM = UiKit.FONT_HEAVY, UiKit.FONT_BOLD, UiKit.FONT_MEDIUM

local FEED_SLOTS = 6
local LINE_TIME = 1.6 -- seconds per commentary line at normal speed
local CHANCE_LINE_TIME = 1.15 -- the chance's build-up reads faster
local GOAL_LINE_TIME = 2.6
local AUTO_PLAY = 9 -- seconds before the PLAY button presses itself
local TACTIC_HOLD = 1.5 -- after a tap, the server's echo of the old tactic doesn't undo it
local FADE_TIME = 0.4
local GREEN = rgb(64, 200, 72)
local GREEN_DARK = rgb(22, 120, 40)
local KIND_STYLE = {
	NEUTRAL = { from = rgb(96, 58, 196), to = rgb(52, 26, 120), text = WHITE },
	ME = { from = rgb(255, 214, 74), to = ORANGE, text = INK },
	GOAL = { from = rgb(255, 236, 140), to = GOLD, text = INK },
	CONCEDE = { from = rgb(255, 92, 120), to = rgb(170, 18, 52), text = WHITE },
}

local MatchHud = {}
MatchHud.__index = MatchHud

---------------------------------------------------------------- small builders

-- Text that fills its box, between minSize and maxSize.
local function label(props: { [string]: any }, maxSize: number, minSize: number?): TextLabel
	props.TextScaled = true
	props.FontFace = props.FontFace or FONT_HEAVY
	local l = text(props)
	create("UITextSizeConstraint", { MaxTextSize = maxSize, MinTextSize = minSize or 8, Parent = l })
	return l
end

local function box(props: { [string]: any }): Frame
	props.BackgroundTransparency = 1
	return frame(props)
end

local function gradient(parent: Instance, from: Color3, to: Color3, rotation: number?)
	return create("UIGradient", { Color = ColorSequence.new(from, to), Rotation = rotation or 90, Parent = parent })
end

-- Readable bar colour from a club colour: dark enough for white text.
local function teamColors(color: Color3): (Color3, Color3)
	local luminance = 0.3 * color.R + 0.59 * color.G + 0.11 * color.B
	local base = if luminance > 0.62 then color:Lerp(INK, 0.55) elseif luminance > 0.45 then color:Lerp(INK, 0.3) else color
	return base:Lerp(WHITE, 0.12), base:Lerp(INK, 0.35)
end

-- Chunky button with a lip (the pixel-kit look), sized by scale. style: gold | violet | green.
local BUTTON_STYLES = {
	gold = { face = { rgb(255, 214, 74), ORANGE }, lip = UiKit.LIP, text = INK },
	violet = { face = { rgb(150, 110, 255), VIOLET }, lip = rgb(40, 16, 96), text = CREAM },
	green = { face = { rgb(130, 236, 96), GREEN }, lip = GREEN_DARK, text = WHITE },
	dark = { face = { PANEL_TOP, PANEL_BOTTOM }, lip = INK, text = CREAM },
}
local function button(parent: Instance, props: { [string]: any }, style: string, onActivated: () -> ())
	local look = BUTTON_STYLES[style]
	props.BackgroundTransparency = 1
	props.AutoButtonColor = false
	props.Text = ""
	props.Parent = parent
	local root = create("TextButton", props)
	local lip = frame({ Name = "Lip", Position = UDim2.new(0, 0, 0, 5), Size = UDim2.new(1, 0, 1, -5), BackgroundColor3 = look.lip, Parent = root })
	corner(lip, 10)
	stroke(lip, INK, 2.5)
	local face = frame({ Name = "Face", Size = UDim2.new(1, 0, 1, -5), BackgroundColor3 = WHITE, Parent = root })
	corner(face, 10)
	gradient(face, look.face[1], look.face[2])
	stroke(face, INK, 2.5)
	-- On the dark face a strong sheen reads as an empty bar.
	frame({ Name = "Sheen", Position = UDim2.new(0, 6, 0, 3), Size = UDim2.new(1, -12, if style == "dark" then 0.22 else 0.36, 0), BackgroundColor3 = WHITE, BackgroundTransparency = if style == "dark" then 0.94 else 0.78, Parent = face })
	corner(face:FindFirstChild("Sheen") :: Frame, 8)
	local function press(down: boolean)
		TweenService:Create(face, TweenInfo.new(0.07), { Position = UDim2.fromOffset(0, if down then 4 else 0) }):Play()
	end
	root.MouseButton1Down:Connect(function()
		press(true)
	end)
	root.MouseButton1Up:Connect(function()
		press(false)
	end)
	root.MouseLeave:Connect(function()
		press(false)
	end)
	root.Activated:Connect(onActivated)
	return root, face, look.text
end

-- Dark rounded card (the panel look without the outer glow, for nested blocks).
local function card(props: { [string]: any }, radius: number?, border: Color3?): Frame
	props.BackgroundColor3 = WHITE
	local c = frame(props)
	corner(c, radius or 12)
	gradient(c, PANEL_TOP, PANEL_BOTTOM)
	stroke(c, border or VIOLET, 2)
	return c
end

---------------------------------------------------------------- construction

function MatchHud.new()
	local self = setmetatable({}, MatchHud)
	self.ui = Commentary.ui()
	self.onEffort = nil :: ((number) -> ())?
	self.onFocus = nil :: ((string) -> ())?
	self.onFinished = nil :: (() -> ())?
	self.token = 0
	self.minute = 0
	self.speed = 1
	self.effort = 2
	self.focus = "ATTACK"
	self.stamina = 100
	self.tacticAt = -math.huge
	self.chapter = {} :: { any }
	self.names = { home = "", away = "", me = "" }
	self.momentChips = {}

	local gui = UiKit.screenGui("MatchHud", 4)
	gui.Enabled = false
	self.gui = gui
	-- Pointer-following bits (the strike reticle) use input coordinates: no safe-area insets.
	local pointer = UiKit.screenGui("MatchPointer", 6)
	pointer.ScreenInsets = Enum.ScreenInsets.None
	pointer.Enabled = false
	self.pointerGui = pointer
	-- The band under Roblox's top-bar buttons: a broadcast strip, so the studio has no bare gap above
	-- its panels.
	local top = UiKit.screenGui("MatchTop", 3)
	top.ScreenInsets = Enum.ScreenInsets.None
	top.Enabled = false
	self.topGui = top

	self:_buildBackdrop()
	self:_buildTopBand()
	self:_buildStudio()
	self:_buildPlay()
	self:_buildPopup()
	self:_buildResult()
	return self
end

function MatchHud:_buildBackdrop()
	-- Over the blurred stadium: darker at the edges so the panels read.
	local backdrop = frame({ Name = "Backdrop", Position = UDim2.fromOffset(-200, -200), Size = UDim2.new(1, 400, 1, 400), BackgroundColor3 = WHITE, BackgroundTransparency = 0.18, ZIndex = 0, Parent = self.gui })
	create("UIGradient", {
		Color = ColorSequence.new(rgb(30, 12, 64), INK),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(0.5, 0.45), NumberSequenceKeypoint.new(1, 0.15) }),
		Rotation = 90,
		Parent = backdrop,
	})
	self.backdrop = backdrop
end

function MatchHud:_buildTopBand()
	local GuiService = game:GetService("GuiService")
	local band = frame({ Name = "TopBand", Size = UDim2.new(1, 0, 0, 58), BackgroundColor3 = WHITE, Parent = self.topGui })
	gradient(band, rgb(44, 20, 92), INK)
	frame({ Name = "Edge", AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 3), BackgroundColor3 = VIOLET, Parent = band })
	frame({ Name = "EdgeGold", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 1), Size = UDim2.new(0.34, 0, 0, 3), BackgroundColor3 = GOLD, Parent = band })
	-- Right of Roblox's buttons: LIVE and a scrolling ticker.
	local strip = box({ Name = "Ticker", ClipsDescendants = true, Parent = band })
	local live = frame({ Name = "Live", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 8, 0.5, -1), Size = UDim2.new(0, 74, 0, 26), BackgroundColor3 = RED, Parent = strip })
	corner(live, 6)
	stroke(live, INK, 2)
	label({ Size = UDim2.fromScale(1, 1), Text = "● " .. self.ui.Live, TextXAlignment = Enum.TextXAlignment.Center, Parent = live }, 15, 8)
	local lane = box({ Name = "Lane", Position = UDim2.new(0, 92, 0, 0), Size = UDim2.new(1, -100, 1, -3), ClipsDescendants = true, Parent = strip })
	self.tickerText = label({ Name = "Text", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(1, 0.5), Size = UDim2.new(0, 1400, 0, 22), Text = "", FontFace = FONT_BOLD, TextColor3 = CREAM, TextXAlignment = Enum.TextXAlignment.Left, TextScaled = false, TextSize = 18, Parent = lane }, 18, 10)
	self.tickerLane = lane
	local function fit()
		local inset = GuiService.TopbarInset
		local height = if inset and inset.Height > 0 then inset.Height else 58
		band.Size = UDim2.new(1, 0, 0, height + 6)
		local left = if inset and inset.Width > 0 then inset.Min.X else 180
		strip.Position = UDim2.new(0, left, 0, 0)
		strip.Size = UDim2.new(1, -left - 8, 1, -3)
	end
	pcall(function()
		GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(fit)
	end)
	pcall(fit)
	self.topBand = band
end

-- League news crawling across the top strip.
function MatchHud:_runTicker()
	local token = self.token
	local items = self.ui.Ticker or {}
	local parts = { string.upper(self.names.home .. "  —  " .. self.names.away) }
	for _, item in items do
		table.insert(parts, item)
	end
	self.tickerText.Text = table.concat(parts, "     ★     ")
	task.spawn(function()
		while self.token == token do
			local width = math.max(self.tickerText.TextBounds.X, 400)
			local lane = math.max(self.tickerLane.AbsoluteSize.X, 300)
			self.tickerText.Size = UDim2.new(0, width + 20, 0, 22)
			self.tickerText.Position = UDim2.new(0, lane, 0.5, 0)
			local tween = TweenService:Create(self.tickerText, TweenInfo.new((lane + width) / 70, Enum.EasingStyle.Linear), { Position = UDim2.new(0, -width, 0.5, 0) })
			tween:Play()
			tween.Completed:Wait()
		end
	end)
end

-- Broadcast scoreboard: team bars in club colours, the score, the minute in the middle.
function MatchHud:_scoreboard(parent: Instance, props: { [string]: any })
	local root = box(props)
	root.Parent = parent
	local refs = { sides = {} }
	for i, anchor in { 0, 1 } do
		local bar = frame({ Name = "Team" .. i, AnchorPoint = Vector2.new(anchor, 0.5), Position = UDim2.fromScale(anchor, 0.5), Size = UDim2.fromScale(0.39, 0.78), BackgroundColor3 = WHITE, Parent = root })
		corner(bar, 10)
		stroke(bar, INK, 2.5)
		local grad = gradient(bar, WHITE, WHITE, 90)
		local crest = box({ Name = "Crest", AnchorPoint = Vector2.new(anchor, 0.5), Position = UDim2.new(anchor, if i == 1 then 6 else -6, 0.5, 0), Size = UDim2.fromScale(1, 1.18), Parent = bar })
		create("UIAspectRatioConstraint", { AspectRatio = 1, Parent = crest })
		local name = label({
			Name = "Name",
			AnchorPoint = Vector2.new(anchor, 0.5),
			Position = UDim2.new(anchor, if i == 1 then 0 else 0, 0.5, 0),
			Size = UDim2.new(0.66, 0, 0.62, 0),
			Text = "",
			TextColor3 = WHITE,
			TextXAlignment = Enum.TextXAlignment.Center,
			Parent = bar,
		}, 26, 10)
		name.Position = UDim2.fromScale(if i == 1 then 0.61 else 0.39, 0.5)
		name.Size = UDim2.fromScale(0.7, 0.6) -- clear of the crest
		name.AnchorPoint = Vector2.new(0.5, 0.5)
		outline(name, 2)
		refs.sides[i] = { bar = bar, grad = grad, crest = crest, name = name }
	end
	local middle = frame({ Name = "Middle", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.21, 1), BackgroundColor3 = NAVY, Parent = root })
	corner(middle, 12)
	stroke(middle, GOLD, 2.5)
	gradient(middle, rgb(40, 22, 84), NAVY)
	for i, anchor in { 0, 1 } do
		local goals = label({ Name = "Goals" .. i, AnchorPoint = Vector2.new(anchor, 0.5), Position = UDim2.fromScale(anchor, 0.5), Size = UDim2.fromScale(0.3, 0.8), Text = "0", TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Center, Parent = middle }, 44, 12)
		outline(goals, 2.5)
		refs["goals" .. i] = goals
	end
	local chip = frame({ Name = "Minute", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.38, 0.62), BackgroundColor3 = WHITE, Parent = middle })
	corner(chip, 8)
	stroke(chip, INK, 2)
	gradient(chip, WHITE, rgb(205, 205, 220))
	refs.minute = label({ Size = UDim2.fromScale(1, 0.9), Position = UDim2.fromScale(0, 0.05), Text = "0'", TextColor3 = INK, TextXAlignment = Enum.TextXAlignment.Center, Parent = chip }, 24, 9)
	refs.pop = create("UIScale", { Parent = middle })
	return refs
end

function MatchHud:_buildStudio()
	local ui = self.ui
	local studio = box({ Name = "Studio", Size = UDim2.fromScale(1, 1), ZIndex = 2, Parent = self.gui })
	create("UIPadding", { PaddingLeft = UDim.new(0.012, 0), PaddingRight = UDim.new(0.012, 0), PaddingTop = UDim.new(0.015, 0), PaddingBottom = UDim.new(0.02, 0), Parent = studio })
	self.studio = studio

	-- Header: commentator badge, scoreboard, speed.
	local header = box({ Name = "Header", Size = UDim2.fromScale(1, 0.13), Parent = studio })
	local mic = frame({ Name = "Mic", Size = UDim2.fromScale(0.2, 1), BackgroundColor3 = WHITE, Parent = header })
	corner(mic, 12)
	gradient(mic, PANEL_TOP, PANEL_BOTTOM)
	stroke(mic, VIOLET, 2)
	local micIcon = frame({ Name = "Icon", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 6, 0.5, 0), Size = UDim2.fromScale(0.8, 0.8), BackgroundColor3 = WHITE, Parent = mic })
	create("UIAspectRatioConstraint", { AspectRatio = 1, Parent = micIcon })
	corner(micIcon)
	gradient(micIcon, rgb(150, 110, 255), VIOLET)
	stroke(micIcon, GOLD, 2)
	label({ Size = UDim2.fromScale(1, 1), Text = "🎙", TextXAlignment = Enum.TextXAlignment.Center, Parent = micIcon }, 30)
	local who = label({ Name = "Who", Position = UDim2.fromScale(0.36, 0.14), Size = UDim2.fromScale(0.6, 0.38), Text = ui.Commentator, TextColor3 = LILAC, Parent = mic }, 18, 8)
	outline(who, 1.5)
	local live = frame({ Name = "Live", Position = UDim2.fromScale(0.36, 0.56), Size = UDim2.fromScale(0.34, 0.3), BackgroundColor3 = RED, Parent = mic })
	corner(live, 6)
	self.liveText = label({ Size = UDim2.fromScale(1, 1), Text = "● " .. ui.Live, TextXAlignment = Enum.TextXAlignment.Center, Parent = live }, 14, 7)

	self.board = self:_scoreboard(header, { Name = "Scoreboard", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0), Size = UDim2.fromScale(0.56, 1) })

	local speed, speedFace = button(header, { Name = "Speed", AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromScale(0.2, 1) }, "dark", function()
		self:_toggleSpeed()
	end)
	self.speedLabel = label({ Size = UDim2.fromScale(1, 1), Text = "»  ×1", TextColor3 = CREAM, TextXAlignment = Enum.TextXAlignment.Center, Parent = speedFace }, 26, 10)
	outline(self.speedLabel, 2)
	self.speedButton = speed

	local top, bottomGap = 0.155, 0.0
	-- Left: your player and energy.
	local left = box({ Name = "Left", Position = UDim2.fromScale(0, top), Size = UDim2.fromScale(0.2, 1 - top - bottomGap), Parent = studio })
	self:_buildPlayerCard(left)
	-- Centre: the feed.
	local feed = box({ Name = "Feed", Position = UDim2.fromScale(0.215, top), Size = UDim2.fromScale(0.57, 0.715), Parent = studio })
	self:_buildFeed(feed)
	-- Right: tactics and the match so far.
	local right = box({ Name = "Right", AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, top), Size = UDim2.fromScale(0.2, 1 - top - bottomGap), Parent = studio })
	self:_buildTactics(right)

	-- PLAY: under the feed when your moment comes.
	local play, playFace = button(studio, { Name = "Play", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 1), Size = UDim2.fromScale(0.36, 0.115), Visible = false, ZIndex = 5 }, "green", function()
		self:_pressPlay()
	end)
	self.playLabel = label({ Size = UDim2.fromScale(0.9, 0.8), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Text = "▶  " .. ui.Play, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Center, Parent = playFace }, 34, 12)
	outline(self.playLabel, 2.5)
	self.playPop = create("UIScale", { Parent = play })
	self.playButton = play
	-- When there's no moment the strip under the feed says what's on.
	local status = frame({ Name = "Status", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 1), Size = UDim2.fromScale(0.57, 0.1), BackgroundColor3 = WHITE, Parent = studio })
	corner(status, 10)
	gradient(status, PANEL_TOP, PANEL_BOTTOM)
	stroke(status, VIOLET, 2)
	self.statusText = label({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.94, 0.6), Text = "", TextColor3 = LILAC, FontFace = FONT_BOLD, TextXAlignment = Enum.TextXAlignment.Center, Parent = status }, 20, 9)
	self.statusBar = status
end

function MatchHud:_buildPlayerCard(column: Frame)
	local ui = self.ui
	local panel = UiKit.panel({ Name = "Player", Size = UDim2.fromScale(1, 0.72), Parent = column }, 14, GOLD)
	local title = label({ Position = UDim2.fromScale(0.08, 0.035), Size = UDim2.fromScale(0.84, 0.075), Text = ui.YourPlayer, TextColor3 = LILAC, Parent = panel }, 16, 8)
	outline(title, 1.5)
	-- Shirt: club colours, the number big, the face if the texture loaded.
	local shirt = frame({ Name = "Shirt", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.13), Size = UDim2.fromScale(0.84, 0.46), BackgroundColor3 = WHITE, Parent = panel })
	corner(shirt, 12)
	stroke(shirt, INK, 2.5)
	self.shirtGradient = gradient(shirt, WHITE, WHITE, 115)
	local face = create("ImageLabel", { Name = "Face", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0.06, 0.5), Size = UDim2.fromScale(0.42, 0.8), BackgroundTransparency = 1, ScaleType = Enum.ScaleType.Fit, Visible = false, Parent = shirt })
	face:SetAttribute("Image", "PlayerMain/HeadFront")
	face:AddTag("NfsImage") -- ImageLoader fills it and makes it visible
	self.shirtNumber = label({ Name = "Number", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.46), Size = UDim2.fromScale(0.8, 0.8), Text = "10", TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Center, Parent = shirt }, 80, 14)
	outline(self.shirtNumber, 3)
	-- The number sits beside the face once the face has loaded, centred otherwise.
	face:GetPropertyChangedSignal("Visible"):Connect(function()
		self.shirtNumber.Position = UDim2.fromScale(if face.Visible then 0.72 else 0.5, 0.46)
		self.shirtNumber.Size = UDim2.fromScale(if face.Visible then 0.5 else 0.8, 0.8)
	end)
	self.playerName = label({ Name = "Name", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.61), Size = UDim2.fromScale(0.9, 0.1), Text = "", TextColor3 = GOLD, TextXAlignment = Enum.TextXAlignment.Center, Parent = panel }, 26, 9)
	outline(self.playerName, 2)
	-- Rating and the three numbers that matter.
	local rating = frame({ Name = "Rating", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.725), Size = UDim2.fromScale(0.84, 0.1), BackgroundColor3 = NAVY, Parent = panel })
	corner(rating, 8)
	stroke(rating, GOLD, 2)
	self.ratingText = label({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.92, 0.72), Text = ui.Rating .. "  6.0", TextColor3 = GOLD, TextXAlignment = Enum.TextXAlignment.Center, Parent = rating }, 20, 8)
	self.ratingBox = rating
	self.ratingStroke = rating:FindFirstChildOfClass("UIStroke")
	self.ratingPop = create("UIScale", { Parent = rating })
	-- The last change (+0.9 / -0.2) pops beside the rating.
	self.ratingDelta = label({ Name = "Delta", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 6, 0, 0), Size = UDim2.fromScale(0.4, 0.9), Text = "", TextColor3 = LIME, TextXAlignment = Enum.TextXAlignment.Center, Visible = false, ZIndex = 5, Parent = rating }, 22, 9)
	outline(self.ratingDelta, 2)
	self.ratingDeltaPop = create("UIScale", { Parent = self.ratingDelta })
	self.ratingValue = 6
	self.statText = {}
	for i, key in { "Goals", "Assists", "Shots" } do
		local cell = box({ Name = key, Position = UDim2.fromScale(0.08 + (i - 1) * 0.28, 0.84), Size = UDim2.fromScale(0.28, 0.14), Parent = panel })
		local value = label({ Size = UDim2.fromScale(1, 0.6), Text = "0", TextColor3 = CREAM, TextXAlignment = Enum.TextXAlignment.Center, Parent = cell }, 26, 10)
		outline(value, 2)
		label({ Position = UDim2.fromScale(0, 0.62), Size = UDim2.fromScale(1, 0.34), Text = self.ui[key], FontFace = FONT_BOLD, TextColor3 = LILAC, TextXAlignment = Enum.TextXAlignment.Center, Parent = cell }, 12, 6)
		self.statText[key] = value
	end

	-- Energy: heart and bar, as in the reference.
	local energy = card({ Name = "Energy", AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.fromScale(1, 0.24) }, 12, rgb(255, 92, 120))
	energy.Parent = column
	local heart = label({ Name = "Heart", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0.03, 0.56), Size = UDim2.fromScale(0.3, 0.8), Text = "❤", TextColor3 = rgb(255, 60, 90), TextXAlignment = Enum.TextXAlignment.Center, Parent = energy }, 48, 12)
	outline(heart, 2)
	self.heartPop = create("UIScale", { Parent = heart })
	label({ Position = UDim2.fromScale(0.34, 0.1), Size = UDim2.fromScale(0.62, 0.28), Text = ui.Energy, TextColor3 = LILAC, Parent = energy }, 16, 7)
	local track = frame({ Name = "Track", Position = UDim2.fromScale(0.34, 0.46), Size = UDim2.fromScale(0.6, 0.38), BackgroundColor3 = INK, Parent = energy })
	corner(track, 8)
	stroke(track, INK, 2)
	local fill = frame({ Name = "Fill", Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, Parent = track })
	corner(fill, 8)
	self.energyGradient = gradient(fill, rgb(150, 255, 110), rgb(50, 190, 60))
	self.energyFill = fill
	self.energyText = label({ Size = UDim2.fromScale(1, 0.86), Position = UDim2.fromScale(0, 0.07), Text = "100%", TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 3, Parent = track }, 18, 7)
	outline(self.energyText, 2)
end

function MatchHud:_buildFeed(holder: Frame)
	local panel = UiKit.panel({ Name = "Panel", Size = UDim2.fromScale(1, 1), Parent = holder }, 14)
	self.feedPanel = panel
	local list = box({ Name = "Slots", Position = UDim2.fromScale(0.025, 0.04), Size = UDim2.fromScale(0.95, 0.92), Parent = panel })
	self.slots = {}
	local gap = 0.022
	local height = (1 - gap * (FEED_SLOTS - 1)) / FEED_SLOTS
	for i = 1, FEED_SLOTS do
		local slot = box({ Name = "Slot" .. i, Position = UDim2.fromScale(0, (i - 1) * (height + gap)), Size = UDim2.fromScale(1, height), Parent = list })
		-- The empty board: faint outlines waiting to be filled.
		local empty = frame({ Name = "Empty", Size = UDim2.fromScale(1, 1), BackgroundColor3 = INK, BackgroundTransparency = 0.55, Parent = slot })
		corner(empty, 10)
		stroke(empty, VIOLET, 1.5, 0.55)
		local bar = frame({ Name = "Bar", Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, Visible = false, Parent = slot })
		corner(bar, 10)
		local barStroke = stroke(bar, INK, 2.5)
		local grad = gradient(bar, WHITE, WHITE)
		frame({ Name = "Sheen", Position = UDim2.new(0, 8, 0, 3), Size = UDim2.new(1, -16, 0.32, 0), BackgroundColor3 = WHITE, BackgroundTransparency = 0.8, Parent = bar })
		corner(bar:FindFirstChild("Sheen") :: Frame, 6)
		-- Stopwatch with the minute on the first line of a chance (and on goals).
		local watch = frame({ Name = "Watch", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, -4, 0.5, 0), Size = UDim2.fromScale(1.25, 1.25), BackgroundColor3 = WHITE, Visible = false, ZIndex = 3, Parent = bar })
		create("UIAspectRatioConstraint", { AspectRatio = 1, Parent = watch })
		corner(watch)
		gradient(watch, WHITE, rgb(190, 190, 205))
		stroke(watch, INK, 2.5)
		local watchText = label({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.54), Size = UDim2.fromScale(0.78, 0.5), Text = "", TextColor3 = INK, TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 4, Parent = watch }, 22, 7)
		local line = label({ Name = "Text", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.86, 0.74), Text = "", FontFace = FONT_BOLD, TextXAlignment = Enum.TextXAlignment.Center, TextWrapped = true, ZIndex = 3, Parent = bar }, 22, 9)
		local lineStroke = outline(line, 1.5)
		local pop = create("UIScale", { Parent = bar })
		self.slots[i] = { slot = slot, empty = empty, bar = bar, grad = grad, stroke = barStroke, watch = watch, watchText = watchText, text = line, textStroke = lineStroke, pop = pop, limit = line:FindFirstChildOfClass("UITextSizeConstraint") }
	end
	-- One text size for every line (from the bar height); only long lines shrink below it.
	local function sizeText()
		local height = self.slots[1].slot.AbsoluteSize.Y
		if height > 0 then
			for _, slot in self.slots do
				slot.limit.MaxTextSize = math.clamp(math.floor(height * 0.5), 12, 26)
			end
		end
	end
	self.slots[1].slot:GetPropertyChangedSignal("AbsoluteSize"):Connect(sizeText)
	sizeText()
end

function MatchHud:_buildTactics(column: Frame)
	local ui = self.ui
	local function tacticCard(name: string, y: number, onTap: () -> ())
		local b, face = button(column, { Name = name, Position = UDim2.fromScale(0, y), Size = UDim2.fromScale(1, 0.25) }, "violet", onTap)
		local icon = frame({ Name = "Icon", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0.05, 0.5), Size = UDim2.fromScale(0.7, 0.7), BackgroundColor3 = WHITE, Parent = face })
		create("UIAspectRatioConstraint", { AspectRatio = 1, Parent = icon })
		corner(icon)
		gradient(icon, rgb(130, 236, 96), GREEN)
		stroke(icon, INK, 2.5)
		local glyph = label({ Size = UDim2.fromScale(1, 1), Text = "", TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Center, Parent = icon }, 34, 10)
		outline(glyph, 2)
		local title = label({ Position = UDim2.fromScale(0.42, 0.12), Size = UDim2.fromScale(0.54, 0.34), Text = "", TextColor3 = WHITE, Parent = face }, 22, 8)
		outline(title, 2)
		local value = label({ Position = UDim2.fromScale(0.42, 0.52), Size = UDim2.fromScale(0.54, 0.32), Text = "", TextColor3 = rgb(255, 226, 120), Parent = face }, 18, 7)
		outline(value, 1.5)
		return { button = b, glyph = glyph, title = title, value = value }
	end
	self.workCard = tacticCard("Work", 0, function()
		self:_openChooser("WORK")
	end)
	self.workCard.glyph.Text = "❤"
	self.workCard.title.Text = ui.Work
	self.focusCard = tacticCard("Focus", 0.28, function()
		self:_openChooser("FOCUS")
	end)
	self.focusCard.title.Text = ui.Focus

	-- The match so far: a chip per moment, the timeline with the goals.
	local summary = card({ Name = "Summary", Position = UDim2.fromScale(0, 0.565), Size = UDim2.fromScale(1, 0.435) }, 12)
	summary.Parent = column
	local mTitle = label({ Position = UDim2.fromScale(0.07, 0.05), Size = UDim2.fromScale(0.86, 0.14), Text = ui.Moments, TextColor3 = LILAC, Parent = summary }, 15, 7)
	outline(mTitle, 1.5)
	local chips = box({ Name = "Chips", Position = UDim2.fromScale(0.07, 0.21), Size = UDim2.fromScale(0.86, 0.26), Parent = summary })
	create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0.025, 0), SortOrder = Enum.SortOrder.LayoutOrder, VerticalAlignment = Enum.VerticalAlignment.Center, Parent = chips })
	self.chipHolder = chips
	local tTitle = label({ Position = UDim2.fromScale(0.07, 0.52), Size = UDim2.fromScale(0.86, 0.14), Text = ui.Timeline, TextColor3 = LILAC, Parent = summary }, 15, 7)
	outline(tTitle, 1.5)
	local track = frame({ Name = "Timeline", Position = UDim2.fromScale(0.07, 0.72), Size = UDim2.fromScale(0.86, 0.1), BackgroundColor3 = INK, Parent = summary })
	corner(track, 6)
	stroke(track, INK, 2)
	local fill = frame({ Name = "Fill", Size = UDim2.fromScale(0, 1), BackgroundColor3 = WHITE, Parent = track })
	corner(fill, 6)
	gradient(fill, rgb(150, 110, 255), VIOLET, 0)
	frame({ Name = "Half", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(0, 2, 1.6, 0), BackgroundColor3 = CREAM, ZIndex = 3, Parent = track })
	self.timeline, self.timeFill = track, fill
	for i, mark in { "0'", "45'", "90'" } do
		label({ AnchorPoint = Vector2.new((i - 1) / 2, 0), Position = UDim2.new((i - 1) / 2, 0, 1.25, 0), Size = UDim2.fromScale(0.3, 1.3), Text = mark, FontFace = FONT_BOLD, TextColor3 = LILAC, TextXAlignment = if i == 1 then Enum.TextXAlignment.Left elseif i == 3 then Enum.TextXAlignment.Right else Enum.TextXAlignment.Center, Parent = track }, 12, 6)
	end
end

function MatchHud:_buildPlay()
	local ui = self.ui
	local play = box({ Name = "Play", Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 2, Parent = self.gui })
	self.play = play
	self.miniBoard = self:_scoreboard(play, { Name = "Scoreboard", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 6), Size = UDim2.fromScale(0.5, 0.095) })

	-- Time before the presser gets there.
	local timer = box({ Name = "Timer", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0.115, 4), Size = UDim2.fromScale(0.34, 0.05), Parent = play })
	local clock = label({ AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromScale(0.09, 1.3), Text = "⏱", TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Center, Parent = timer }, 30, 10)
	outline(clock, 2)
	local track = frame({ Name = "Track", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(1, 0.5), Size = UDim2.fromScale(0.89, 0.62), BackgroundColor3 = INK, Parent = timer })
	corner(track, 8)
	stroke(track, INK, 2.5)
	local fill = frame({ Name = "Fill", Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, Parent = track })
	corner(fill, 8)
	self.timerGradient = gradient(fill, rgb(150, 255, 110), rgb(50, 190, 60))
	self.timerFill = fill
	self.timer = timer

	-- Hint at the bottom.
	local hint = frame({ Name = "Hint", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -10), Size = UDim2.fromScale(0.58, 0.085), BackgroundColor3 = WHITE, Visible = false, Parent = play })
	corner(hint, 14)
	gradient(hint, PANEL_TOP, PANEL_BOTTOM)
	stroke(hint, GOLD, 2.5)
	self.hintText = label({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.94, 0.62), Text = "", FontFace = FONT_BOLD, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Center, Parent = hint }, 22, 9)
	outline(self.hintText, 1.5)
	self.hint = hint

	-- Strike screen: stopwatch bottom-left, how the hit works on the right.
	local strike = box({ Name = "Strike", Size = UDim2.fromScale(1, 1), Visible = false, Parent = play })
	self.strike = strike
	local watch = box({ Name = "Stopwatch", AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0.02, 0, 1, -12), Size = UDim2.fromScale(0.36, 0.085), Parent = strike })
	local watchIcon = frame({ Name = "Icon", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromScale(1.2, 1.2), BackgroundColor3 = WHITE, ZIndex = 3, Parent = watch })
	create("UIAspectRatioConstraint", { AspectRatio = 1, Parent = watchIcon })
	corner(watchIcon)
	gradient(watchIcon, WHITE, rgb(190, 190, 205))
	stroke(watchIcon, INK, 2.5)
	label({ Size = UDim2.fromScale(1, 1), Text = "⏱", TextColor3 = INK, TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 4, Parent = watchIcon }, 30)
	local strikeTrack = frame({ Name = "Track", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(1, 0.5), Size = UDim2.fromScale(0.86, 0.66), BackgroundColor3 = INK, Parent = watch })
	corner(strikeTrack, 10)
	stroke(strikeTrack, INK, 2.5)
	local strikeFill = frame({ Name = "Fill", Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, Parent = strikeTrack })
	corner(strikeFill, 10)
	gradient(strikeFill, rgb(120, 220, 255), rgb(30, 130, 230))
	self.strikeFill = strikeFill
	local title = label({ AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.13), Size = UDim2.fromScale(0.5, 0.08), Text = ui.StrikeHint, TextColor3 = GOLD, TextXAlignment = Enum.TextXAlignment.Center, Parent = strike }, 40, 14)
	outline(title, 3)
	self.strikeTitle = title
	local legend = card({ Name = "Legend", AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(0.98, 0, 1, -12), Size = UDim2.fromScale(0.27, 0.27) }, 14, GOLD)
	legend.Parent = strike
	-- A small ball with the three zones.
	local ball = frame({ Name = "Ball", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0.05, 0.5), Size = UDim2.fromScale(0.78, 0.78), BackgroundColor3 = WHITE, Parent = legend })
	create("UIAspectRatioConstraint", { AspectRatio = 1, Parent = ball })
	corner(ball)
	stroke(ball, INK, 2.5)
	local low = frame({ Name = "Low", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.64), Size = UDim2.fromScale(0.36, 0.22), BackgroundColor3 = rgb(120, 220, 255), Parent = ball })
	corner(low, 6)
	local high = frame({ Name = "High", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 0.36), Size = UDim2.fromScale(0.36, 0.22), BackgroundColor3 = LIME, Parent = ball })
	corner(high, 6)
	local sideL = frame({ Name = "Side", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0.08, 0.5), Size = UDim2.fromScale(0.18, 0.3), BackgroundColor3 = GOLD, Parent = ball })
	corner(sideL, 6)
	local sideR = frame({ Name = "Side", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(0.92, 0.5), Size = UDim2.fromScale(0.18, 0.3), BackgroundColor3 = GOLD, Parent = ball })
	corner(sideR, 6)
	for i, spec in { { ui.StrikeHigh, LIME }, { ui.StrikeSide, GOLD }, { ui.StrikeLow, rgb(120, 220, 255) } } do
		local l = label({ Position = UDim2.fromScale(0.42, 0.1 + (i - 1) * 0.28), Size = UDim2.fromScale(0.55, 0.22), Text = spec[1], FontFace = FONT_BOLD, TextColor3 = spec[2], Parent = legend }, 15, 7)
		outline(l, 1.5)
	end
	-- Reticle that follows the pointer over the ball.
	local reticle = box({ Name = "Reticle", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(46, 46), Visible = false, Parent = self.pointerGui })
	local ring = box({ Size = UDim2.fromScale(1, 1), Parent = reticle })
	corner(ring)
	stroke(ring, RED, 3)
	local dot = frame({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(8, 8), BackgroundColor3 = RED, Parent = reticle })
	corner(dot)
	self.reticle = reticle

	-- Result banner in the middle of the pitch.
	local banner, shadow = UiKit.bigText({ Name = "Banner", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.36), Size = UDim2.fromScale(0.6, 0.16), Text = "", TextColor3 = GOLD, TextXAlignment = Enum.TextXAlignment.Center, Visible = false, Parent = play }, 5, Vector2.new(0, 5), 96)
	self.bannerLabel, self.bannerShadow = banner, shadow
	self.bannerPop = create("UIScale", { Parent = banner })
	self.bannerShadowPop = create("UIScale", { Parent = shadow })
end

function MatchHud:_buildPopup()
	local root = box({ Name = "Chooser", Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 8, Parent = self.gui })
	local dim = create("TextButton", { Name = "Dim", Position = UDim2.fromOffset(-200, -200), Size = UDim2.new(1, 400, 1, 400), BackgroundColor3 = INK, BackgroundTransparency = 0.35, AutoButtonColor = false, Text = "", Parent = root })
	dim.Activated:Connect(function()
		self:_closeChooser()
	end)
	local panel = UiKit.panel({ Name = "Panel", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.52), Size = UDim2.fromScale(0.7, 0.62), Parent = root }, 16, GOLD)
	self.chooserPop = create("UIScale", { Parent = panel })
	local title, shadow = UiKit.bigText({ Name = "Title", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.05), Size = UDim2.fromScale(0.8, 0.16), Text = "", TextColor3 = GOLD, TextXAlignment = Enum.TextXAlignment.Center, Parent = panel }, 3, Vector2.new(0, 3), 40)
	self.chooserTitle, self.chooserShadow = title, shadow
	self.chooserOptions = box({ Name = "Options", Position = UDim2.fromScale(0.04, 0.27), Size = UDim2.fromScale(0.92, 0.66), Parent = panel })
	self.chooser = root
end

function MatchHud:_buildResult()
	local ui = self.ui
	local root = box({ Name = "Result", Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 10, Parent = self.gui })
	self.resultRoot = root
	frame({ Name = "Dim", Position = UDim2.fromOffset(-200, -200), Size = UDim2.new(1, 400, 1, 400), BackgroundColor3 = INK, BackgroundTransparency = 0.35, Parent = root })
	local panel = UiKit.panel({ Name = "Panel", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.56, 0.86), Parent = root }, 16, GOLD)
	self.resultPop = create("UIScale", { Parent = panel })
	local title, shadow = UiKit.bigText({ Name = "Title", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.04), Size = UDim2.fromScale(0.9, 0.15), Text = "", TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Center, Parent = panel }, 4, Vector2.new(0, 4), 56)
	self.resultTitle, self.resultShadow = title, shadow
	self.resultScore = label({ AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.2), Size = UDim2.fromScale(0.9, 0.08), Text = "", TextXAlignment = Enum.TextXAlignment.Center, Parent = panel }, 26, 10)
	outline(self.resultScore, 2)
	self.statValues = {}
	for i, key in { "Goals", "Assists", "Rating" } do
		local cell = card({ Name = key, Position = UDim2.fromScale(0.05 + (i - 1) * 0.31, 0.32), Size = UDim2.fromScale(0.28, 0.27) }, 12, if key == "Rating" then GOLD else VIOLET)
		cell.Parent = panel
		local value = label({ AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.08), Size = UDim2.fromScale(0.9, 0.56), Text = "0", TextColor3 = if key == "Rating" then GOLD else CREAM, TextXAlignment = Enum.TextXAlignment.Center, Parent = cell }, 48, 14)
		outline(value, 2.5)
		label({ AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.68), Size = UDim2.fromScale(0.9, 0.22), Text = ui[key], FontFace = FONT_BOLD, TextColor3 = LILAC, TextXAlignment = Enum.TextXAlignment.Center, Parent = cell }, 16, 7)
		self.statValues[key] = value
	end
	self.resultDetail = label({ AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.62), Size = UDim2.fromScale(0.9, 0.06), Text = "", FontFace = FONT_MEDIUM, TextXAlignment = Enum.TextXAlignment.Center, Parent = panel }, 18, 8)
	local chips = box({ Name = "Chips", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.7), Size = UDim2.fromScale(0.9, 0.08), Parent = panel })
	create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0.03, 0), Parent = chips })
	local function chip(color: Color3): TextLabel
		local c = frame({ Size = UDim2.fromScale(0.3, 1), BackgroundColor3 = NAVY, Parent = chips })
		corner(c, 8)
		stroke(c, color, 2)
		local l = label({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.9, 0.7), Text = "", TextXAlignment = Enum.TextXAlignment.Center, Parent = c }, 20, 8)
		outline(l, 1.5)
		return l
	end
	self.resultXp, self.resultLevel = chip(LIME), chip(GOLD)
	local continue, face = button(panel, { Name = "Continue", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 0.95), Size = UDim2.fromScale(0.6, 0.13) }, "gold", function()
		self:hide()
		if self.onFinished then
			self.onFinished()
		end
	end)
	local cl = label({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.9, 0.62), Text = ui.Continue, TextColor3 = INK, TextXAlignment = Enum.TextXAlignment.Center, Parent = face }, 30, 10)
	outline(cl, 1.5, rgb(255, 226, 120))
	self.continueButton = continue
end

---------------------------------------------------------------- scoreboard, feed, tactics

local function setBoardClub(refs, index: number, club)
	local side = refs.sides[index]
	local from, to = teamColors(club.shirt)
	side.grad.Color = ColorSequence.new(from, to)
	for _, child in side.crest:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local badge = UiKit.crest(side.crest, { Size = UDim2.fromScale(1, 1) }, club)
	-- UiKit sizes the letters from an offset size; this badge is sized by scale.
	local letters = badge:FindFirstChild("Letters") :: TextLabel?
	if letters then
		letters.TextScaled = true
		letters.Size = UDim2.fromScale(0.7, 0.5)
		letters.AnchorPoint = Vector2.new(0.5, 0.5)
		letters.Position = UDim2.fromScale(0.5, 0.5)
		create("UITextSizeConstraint", { MaxTextSize = 24, MinTextSize = 6, Parent = letters })
	end
	side.name.Text = string.upper(club.name)
end

function MatchHud:setScore(score: { home: number, away: number }, pop: boolean?)
	local changed = not self.score or self.score.home ~= score.home or self.score.away ~= score.away
	self.score = score
	for _, refs in { self.board, self.miniBoard } do
		refs.goals1.Text = tostring(score.home)
		refs.goals2.Text = tostring(score.away)
		if changed and pop then
			UiKit.pop(refs.pop, 1.25)
		end
	end
end

function MatchHud:_setMinute(minute: number)
	self.minute = minute
	for _, refs in { self.board, self.miniBoard } do
		refs.minute.Text = string.format("%d'", minute)
	end
	self.timeFill.Size = UDim2.fromScale(math.clamp(minute / 90, 0, 1), 1)
end

function MatchHud:_goalMark(minute: number, ours: boolean)
	local dot = frame({ Name = "GoalMark", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(math.clamp(minute / 90, 0, 1), 0.5), Size = UDim2.fromScale(2, 2), BackgroundColor3 = if ours then GOLD else RED, ZIndex = 5, Parent = self.timeline })
	create("UIAspectRatioConstraint", { AspectRatio = 1, DominantAxis = Enum.DominantAxis.Height, Parent = dot })
	corner(dot)
	stroke(dot, INK, 2)
end

local function styleFor(self, kind: string)
	if kind == "US" or kind == "THEM" then
		local club = if kind == "US" then self.home else self.away
		local from, to = teamColors(if club then club.shirt else VIOLET)
		return { from = from, to = to, text = WHITE }
	end
	return KIND_STYLE[kind] or KIND_STYLE.NEUTRAL
end

-- Fills the next slot of the board (a new board for each chance, or when it is full).
function MatchHud:_addLine(line)
	if line.chance or #self.chapter >= FEED_SLOTS then
		self.chapter = {}
		for _, slot in self.slots do
			slot.bar.Visible = false
		end
	end
	table.insert(self.chapter, line)
	local slot = self.slots[#self.chapter]
	local style = styleFor(self, line.kind)
	slot.grad.Color = ColorSequence.new(style.from, style.to)
	slot.text.Text = line.text
	slot.text.TextColor3 = style.text
	slot.textStroke.Color = if style.text == INK then rgb(255, 236, 160) else INK
	slot.textStroke.Transparency = if style.text == INK then 0.4 else 0
	local stamp = line.chance or line.kind == "GOAL" or line.kind == "CONCEDE"
	slot.watch.Visible = stamp
	slot.watchText.Text = string.format("%d'", line.minute)
	slot.text.Position = UDim2.fromScale(if stamp then 0.55 else 0.5, 0.5)
	slot.text.Size = UDim2.fromScale(if stamp then 0.78 else 0.9, 0.66)
	slot.stroke.Color = if line.kind == "GOAL" then rgb(255, 250, 200) else INK
	slot.bar.Visible = true
	-- Slides in from the right.
	slot.bar.Position = UDim2.fromScale(0.06, 0)
	TweenService:Create(slot.bar, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = UDim2.fromScale(0, 0) }):Play()
	UiKit.pop(slot.pop, if line.kind == "GOAL" then 1.12 else 0.94)
end

-- Adds a commentary line (and speaks it if a voice file is set). Returns the text.
function MatchHud:say(key: string, params: { [string]: any }?, minute: number?, chance: boolean?): string
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
	local kind = Commentary.kind(key)
	self:_addLine({ minute = minute or self.minute, text = line, kind = kind, chance = chance == true })
	if key == "OPP_GOAL" or key == "TEAM_GOAL" or key == "YOU_GOAL" or key == "ASSIST_GOAL" or key == "HEADER_GOAL" then
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

function MatchHud:_toggleSpeed()
	self.speed = if self.speed == 1 then 2 else 1
	self.speedLabel.Text = if self.speed == 1 then "»  ×1" else "»»  ×2"
end

local function hearts(n: number): string
	return string.rep("❤", n) .. string.rep("♡", 3 - n)
end

function MatchHud:_showTactics()
	local ui = self.ui
	self.workCard.value.Text = hearts(self.effort) .. "  " .. ui.EffortNames[self.effort]
	self.focusCard.glyph.Text = if self.focus == "ATTACK" then "⚔" else "🛡"
	self.focusCard.value.Text = if self.focus == "ATTACK" then ui.Attack else ui.Defense
end

function MatchHud:_closeChooser()
	self.chooser.Visible = false
end

-- Work rate (1-3 hearts) or focus (attack / defense): big option cards, like the reference.
function MatchHud:_openChooser(which: string)
	local ui = self.ui
	for _, child in self.chooserOptions:GetChildren() do
		child:Destroy()
	end
	local title = if which == "WORK" then ui.Work else ui.Focus
	self.chooserTitle.Text = title
	self.chooserShadow.Text = title
	local options = {}
	if which == "WORK" then
		for n = 1, 3 do
			table.insert(options, { glyph = string.rep("❤", n), name = ui.EffortNames[n], info = ui.EffortInfo[n], picked = n == self.effort, choose = function()
				self:_pickEffort(n)
			end, disabled = n > 1 and self.stamina <= 0 })
		end
	else
		for _, focus in { "ATTACK", "DEFENSE" } do
			table.insert(options, {
				glyph = if focus == "ATTACK" then "⚔" else "🛡",
				name = if focus == "ATTACK" then ui.Attack else ui.Defense,
				info = if focus == "ATTACK" then ui.AttackInfo else ui.DefenseInfo,
				picked = focus == self.focus,
				choose = function()
					self:_pickFocus(focus)
				end,
			})
		end
	end
	local count = #options
	local width = (1 - 0.03 * (count - 1)) / count
	for i, option in options do
		local b, face = button(self.chooserOptions, { Name = "Option" .. i, Position = UDim2.fromScale((i - 1) * (width + 0.03), 0), Size = UDim2.fromScale(width, 1) }, if option.picked then "gold" else "violet", function()
			if option.disabled then
				return
			end
			option.choose()
			self:_closeChooser()
		end)
		local ink = if option.picked then INK else WHITE
		local glyph = label({ AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.06), Size = UDim2.fromScale(0.9, 0.3), Text = option.glyph, TextColor3 = if option.picked then RED else rgb(255, 92, 120), TextXAlignment = Enum.TextXAlignment.Center, Parent = face }, 54, 14)
		outline(glyph, 2)
		local name = label({ AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.4), Size = UDim2.fromScale(0.9, 0.17), Text = option.name, TextColor3 = ink, TextXAlignment = Enum.TextXAlignment.Center, Parent = face }, 28, 10)
		if not option.picked then
			outline(name, 2)
		end
		label({ AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.62), Size = UDim2.fromScale(0.86, 0.3), Text = option.info, FontFace = FONT_BOLD, TextWrapped = true, TextColor3 = if option.picked then INK else LILAC, TextXAlignment = Enum.TextXAlignment.Center, Parent = face }, 18, 8)
		if option.disabled then
			b.Active = false
			face.BackgroundTransparency = 0.5
		end
	end
	self.chooser.Visible = true
	UiKit.pop(self.chooserPop, 0.85)
end

function MatchHud:_pickEffort(n: number)
	if n == self.effort then
		return
	end
	self.effort = n
	self.tacticAt = os.clock()
	self:_showTactics()
	self:say("TACTIC_EFFORT_" .. n)
	UiKit.pop(self.heartPop, 1.4)
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

-- Server state: { stamina, effort, focus, goals, assists, shots, passes, goodPasses }.
function MatchHud:setState(state)
	if typeof(state) ~= "table" then
		return
	end
	local stamina = math.clamp(tonumber(state.stamina) or self.stamina, 0, 100)
	local wasEmpty = self.stamina <= 0
	self.stamina = stamina
	TweenService:Create(self.energyFill, TweenInfo.new(0.4), { Size = UDim2.fromScale(math.max(stamina, 0.001) / 100, 1) }):Play()
	self.energyGradient.Color = if stamina > 50 then ColorSequence.new(rgb(150, 255, 110), rgb(50, 190, 60))
		elseif stamina > 20 then ColorSequence.new(rgb(255, 226, 120), ORANGE)
		else ColorSequence.new(rgb(255, 120, 140), RED)
	self.energyText.Text = string.format("%d%%", math.floor(stamina + 0.5))
	if os.clock() - self.tacticAt > TACTIC_HOLD then
		self.effort = state.effort or self.effort
		self.focus = state.focus or self.focus
		self:_showTactics()
	end
	if state.goals then
		self.statText.Goals.Text = tostring(state.goals)
		self.statText.Assists.Text = tostring(state.assists or 0)
		self.statText.Shots.Text = tostring(state.shots or 0)
	end
	if state.rating then
		self:_setRating(tonumber(state.rating) or self.ratingValue)
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

-- The match rating moves with what you do. During a moment the card is off screen, so the change
-- waits and plays when the studio comes back.
function MatchHud:_setRating(value: number)
	if math.abs(value - self.ratingValue) < 0.05 then
		return
	end
	self.ratingPending = value
	if self.mode == "STUDIO" then
		self:_showRatingChange()
	end
end

function MatchHud:_showRatingChange()
	local value = self.ratingPending
	if not value then
		return
	end
	self.ratingPending = nil
	local from = self.ratingValue
	local delta = value - from
	self.ratingValue = value
	local up = delta > 0
	local color = if up then LIME else rgb(255, 110, 130)
	self.ratingDelta.Text = string.format("%s%.1f", if up then "+" else "−", math.abs(delta))
	self.ratingDelta.TextColor3 = color
	self.ratingDelta.Visible = true
	UiKit.pop(self.ratingDeltaPop, 0.4)
	UiKit.pop(self.ratingPop, if up then 1.18 else 0.88)
	if self.ratingStroke then
		self.ratingStroke.Color = color
	end
	-- Count from the old value to the new one.
	local token = (self.ratingToken or 0) + 1
	self.ratingToken = token
	task.spawn(function()
		local steps = 12
		for i = 1, steps do
			if self.ratingToken ~= token then
				return
			end
			self.ratingText.Text = string.format("%s  %.1f", self.ui.Rating, from + delta * i / steps)
			task.wait(0.035)
		end
		task.wait(2.6)
		if self.ratingToken == token then
			self.ratingDelta.Visible = false
			if self.ratingStroke then
				self.ratingStroke.Color = GOLD
			end
		end
	end)
end

-- One chip per moment in the summary: GOAL, ASSIST or NONE.
function MatchHud:addMomentChip(outcome: string)
	local i = #self.momentChips + 1
	local chip = frame({ Name = "Moment" .. i, LayoutOrder = i, Size = UDim2.fromScale(0.13, 0.9), BackgroundColor3 = if outcome == "GOAL" then GOLD elseif outcome == "ASSIST" then LIME else rgb(70, 50, 120), Parent = self.chipHolder })
	create("UIAspectRatioConstraint", { AspectRatio = 1, DominantAxis = Enum.DominantAxis.Height, Parent = chip })
	corner(chip)
	stroke(chip, INK, 2)
	label({ Size = UDim2.fromScale(1, 1), Text = if outcome == "GOAL" then "⚽" elseif outcome == "ASSIST" then "A" else "•", TextColor3 = INK, TextXAlignment = Enum.TextXAlignment.Center, Parent = chip }, 20, 7)
	table.insert(self.momentChips, chip)
end

---------------------------------------------------------------- match flow

-- clubs resolved by the caller; state: the server's opening { stamina, effort, focus }.
function MatchHud:start(home, away, surname: string, number: number?, state)
	self.token += 1
	self.home, self.away = home, away
	self.names = { home = home.name, away = away.name, me = surname }
	self.chapter = {}
	for _, slot in self.slots do
		slot.bar.Visible = false
	end
	for _, chip in self.momentChips do
		chip:Destroy()
	end
	self.momentChips = {}
	for _, child in self.timeline:GetChildren() do
		if child.Name == "GoalMark" then
			child:Destroy()
		end
	end
	for _, refs in { self.board, self.miniBoard } do
		setBoardClub(refs, 1, home)
		setBoardClub(refs, 2, away)
	end
	local from, to = teamColors(home.shirt)
	self.shirtGradient.Color = ColorSequence.new(from, to)
	self.shirtNumber.Text = tostring(number or "")
	self.playerName.Text = string.upper(surname)
	self.ratingText.Text = self.ui.Rating .. "  6.0"
	self.ratingValue = 6
	self.ratingPending = nil
	self.ratingDelta.Visible = false
	for _, value in self.statText do
		value.Text = "0"
	end
	self.stamina = 100
	self.tacticAt = -math.huge
	self.score = nil
	self:setState(state or { stamina = 100, effort = 2, focus = "ATTACK" })
	self:setScore({ home = 0, away = 0 })
	self:_setMinute(0)
	self:setStatus(self.names.home .. "  —  " .. self.names.away)
	self.playButton.Visible = false
	self.chooser.Visible = false
	self.resultRoot.Visible = false
	self:setMode("STUDIO", true)
	self.gui.Enabled = true
end

function MatchHud:setStatus(value: string)
	self.statusText.Text = value
end

-- Plays the simulated events one line at a time (minute ticking up to each), then calls done.
function MatchHud:playEvents(events: { any }, done: () -> ())
	self.token += 1
	local token = self.token
	task.spawn(function()
		for _, event in events do
			local from = self.minute
			local steps = math.clamp(event.minute - from, 0, 10)
			for step = 1, steps do
				task.wait(0.04 / self.speed)
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
			if event.score then
				self:setScore(event.score, true)
			end
			self:say(key, { n = event.number }, event.minute, event.chance)
			local kind = Commentary.kind(key)
			local wait = if kind == "GOAL" or kind == "CONCEDE" then GOAL_LINE_TIME elseif event.chance or key == "BUILD_ONBALL" or key == "BUILD_RECEIVE" or key == "PROMPT" then CHANCE_LINE_TIME else LINE_TIME
			task.wait(wait / self.speed)
			if token ~= self.token then
				return
			end
		end
		done()
	end)
end

-- Your moment: the PLAY button under the feed (presses itself after a while).
function MatchHud:showPlay(onPlay: () -> ())
	self.token += 1
	local token = self.token
	self.onPlay = onPlay
	self.playButton.Visible = true
	self.statusBar.Visible = false
	UiKit.pop(self.playPop, 0.6)
	task.spawn(function()
		local started = os.clock()
		while token == self.token and self.playButton.Visible do
			local t = os.clock() - started
			self.playPop.Scale = 1 + 0.05 * math.sin(t * 6)
			if t > AUTO_PLAY then
				self:_pressPlay()
				return
			end
			task.wait(1 / 30)
		end
	end)
end

function MatchHud:_pressPlay()
	if not self.playButton.Visible then
		return
	end
	self.playButton.Visible = false
	self.statusBar.Visible = true
	local onPlay = self.onPlay
	self.onPlay = nil
	if onPlay then
		onPlay()
	end
end

-- STUDIO (the commentator's screen) or PLAY (your moment on the pitch).
function MatchHud:setMode(mode: string, instant: boolean?)
	local studio = mode == "STUDIO"
	self.mode = mode
	self.studio.Visible = studio
	self.play.Visible = not studio
	self.pointerGui.Enabled = not studio
	if not studio then
		self.chooser.Visible = false
		self.bannerLabel.Visible = false
		self.bannerShadow.Visible = false
		self:setTimer(nil)
		self:setHint(nil)
		self:hideStrike()
	end
	local goal = if studio then 0.18 else 1
	if studio and self.ratingPending then
		task.delay(FADE_TIME + 0.2, function()
			if self.mode == "STUDIO" then
				self:_showRatingChange()
			end
		end)
	end
	if instant then
		self.backdrop.BackgroundTransparency = goal
		self.backdrop.Visible = studio
		return
	end
	self.backdrop.Visible = true
	local tween = TweenService:Create(self.backdrop, TweenInfo.new(FADE_TIME, Enum.EasingStyle.Quad), { BackgroundTransparency = goal })
	tween.Completed:Once(function()
		if self.mode == mode then
			self.backdrop.Visible = studio
		end
	end)
	tween:Play()
end

-- Time left before the tackle, 1 = plenty, 0 = now; nil hides it.
function MatchHud:setTimer(left: number?)
	self.timer.Visible = left ~= nil
	if left then
		local k = math.clamp(left, 0, 1)
		self.timerFill.Size = UDim2.fromScale(math.max(k, 0.001), 1)
		self.timerGradient.Color = if k > 0.5 then ColorSequence.new(rgb(150, 255, 110), rgb(50, 190, 60))
			elseif k > 0.25 then ColorSequence.new(rgb(255, 226, 120), ORANGE)
			else ColorSequence.new(rgb(255, 120, 140), RED)
	end
end

function MatchHud:setHint(value: string?)
	self.hint.Visible = value ~= nil
	if value and self.hintText.Text ~= value then
		self.hintText.Text = value
	end
end

function MatchHud:showStrike()
	self.strike.Visible = true
	self:setStrikeTimer(1)
	UiKit.pop(create("UIScale", { Parent = self.strikeTitle }), 0.6)
end

function MatchHud:setStrikeTimer(left: number)
	self.strikeFill.Size = UDim2.fromScale(math.clamp(left, 0.001, 1), 1)
end

-- Reticle at a pointer position (input coordinates), nil hides it.
function MatchHud:setReticle(position: Vector2?)
	self.reticle.Visible = position ~= nil
	if position then
		self.reticle.Position = UDim2.fromOffset(position.X, position.Y)
	end
end

function MatchHud:hideStrike()
	self.strike.Visible = false
	self.reticle.Visible = false
end

-- Big word over the pitch: GOAL, SAVE, BLOCKED, ONETWO ... (keys of ui.Banner).
function MatchHud:banner(kind: string, duration: number?)
	local value = self.ui.Banner[kind]
	if not value then
		return
	end
	local good = kind == "GOAL" or kind == "ONETWO" or kind == "PASS" or kind == "CROSS"
	self.bannerLabel.Text = value
	self.bannerShadow.Text = value
	self.bannerLabel.TextColor3 = if kind == "GOAL" then GOLD elseif good then LIME else rgb(255, 120, 140)
	self.bannerLabel.Visible = true
	self.bannerShadow.Visible = true
	UiKit.pop(self.bannerPop, 0.4)
	UiKit.pop(self.bannerShadowPop, 0.4)
	self.bannerToken = (self.bannerToken or 0) + 1
	local token = self.bannerToken
	task.delay(duration or 1.3, function()
		if self.bannerToken == token then
			self.bannerLabel.Visible = false
			self.bannerShadow.Visible = false
		end
	end)
end

function MatchHud:showResult(result, career)
	self.token += 1
	local ui = self.ui
	self:setMode("STUDIO", true)
	self.playButton.Visible = false
	local title = if result.outcome == "WIN" then ui.Win elseif result.outcome == "DRAW" then ui.Draw else ui.Loss
	self.resultTitle.Text = title
	self.resultShadow.Text = title
	self.resultTitle.TextColor3 = if result.outcome == "WIN" then GOLD elseif result.outcome == "DRAW" then CREAM else RED
	self.resultScore.Text = string.format("%s  %d : %d  %s", self.names.home, result.home, result.away, self.names.away)
	self.statValues.Goals.Text = tostring(result.goals)
	self.statValues.Assists.Text = tostring(result.assists)
	self.statValues.Rating.Text = string.format("%.1f", result.rating)
	self.resultDetail.Text = string.format(ui.ShotsLine, result.shots, result.goodPasses, result.passes)
	self.resultXp.Text = string.format(ui.Xp, result.xp)
	self.resultLevel.Text = string.format(ui.Level, if career then career.level else 1)
	self.resultRoot.Visible = true
	UiKit.pop(self.resultPop, 0.6)
end

function MatchHud:hide()
	self.token += 1
	self.gui.Enabled = false
	self.pointerGui.Enabled = false
end

function MatchHud:setUiBoost(_boost: number)
	-- Laid out in screen fractions: nothing to scale.
end

return MatchHud
