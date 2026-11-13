-- Finger hint for the guided first shot and first pass.
--   SHOT: a pulsing ring on the goal; the finger shows press → hold (power bar to the green
--         zone) → release.
--   PASS: the target teammate's ground ring pulses (PassVisuals); the finger presses at the ball,
--         drags to the teammate and lets go, while the power bar fills.
-- The ring and callout sit in a BillboardGui anchored at the target, the finger in another one
-- whose anchor moves, so everything lines up with the 3D scene on any screen. Sizes in pixels are
-- multiplied by the HUD scale (readable on phones).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShotPhysics = require(Shared:WaitForChild("ShotPhysics"))
local PassConfig = require(Shared:WaitForChild("PassConfig"))
local ImageLoader = require(script.Parent:WaitForChild("ImageLoader"))

local rgb = Color3.fromRGB
local GOLD = rgb(255, 191, 31)
local LIME = rgb(170, 240, 40)
local PINK = rgb(255, 120, 140)
local CREAM = rgb(247, 236, 214)
local INK = rgb(18, 6, 31)
local NAVY = rgb(18, 11, 36)
local FONT = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.Heavy, Enum.FontStyle.Italic)

local TEXT = {
	Press = "НАЖМИ И ДЕРЖИ",
	Hold = "ДЕРЖИ…",
	Release = "ОТПУСТИ!",
	Wait = "ДЕРЖИ ДО ЗЕЛЁНОЙ ЗОНЫ",
	Missed = "НАЖМИ НА КРУЖОК",
	PassPress = "ВЕДИ К ПАРТНЁРУ",
	PassRelease = "ОТПУСТИ!",
	PassMissed = "ОТПУСТИ У ПАРТНЁРА",
}

local MARGIN = 360 -- pixels around the shot ring for the callout
local FINGER_SIZE = 96 -- pixels at HUD scale 1
local CALLOUT_HEIGHT = 8.6 -- studs above a pass target (over the teammate's head)

-- Demo timelines (seconds in a loop).
local SHOT_LOOP = 2.6
local ARRIVE, PRESS, RELEASE, FADE = 0.55, 0.7, 1.35, 1.7
local DEMO_POWER = 0.68 -- where the shot demo releases (middle of the green zone)
local PASS_LOOP = 2.9
local P_ARRIVE, P_PRESS, P_DRAG, P_RELEASE = 0.35, 0.5, 1.55, 1.85

local TutorialHint = {}
TutorialHint.__index = TutorialHint

local function create(className: string, props: { [string]: any }): any
	local inst = Instance.new(className)
	local parent = props.Parent
	props.Parent = nil
	for key, value in props do
		inst[key] = value
	end
	inst.Parent = parent
	return inst
end

local function circle(parent: Instance, name: string, color: Color3, thickness: number): (Frame, UIStroke)
	local f = create("Frame", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = parent,
	})
	create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = f })
	local s = create("UIStroke", { Color = color, Thickness = thickness, Parent = f })
	return f, s
end

local function easeOut(t: number): number
	t = math.clamp(t, 0, 1)
	return 1 - (1 - t) ^ 3
end

local function easeInOut(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- Plain finger made of frames, used only if images are unavailable.
local function fallbackFinger(parent: Instance): { GuiObject }
	local parts = {}
	local function piece(name: string, position: UDim2, size: UDim2, radius: number)
		local f = create("Frame", { Name = name, Position = position, Size = size, BackgroundColor3 = CREAM, BorderSizePixel = 0, Parent = parent })
		create("UICorner", { CornerRadius = UDim.new(radius, 0), Parent = f })
		create("UIStroke", { Color = INK, Thickness = 3, Parent = f })
		table.insert(parts, f)
	end
	piece("Index", UDim2.fromScale(0.38, 0.02), UDim2.fromScale(0.22, 0.55), 0.5)
	piece("Palm", UDim2.fromScale(0.22, 0.42), UDim2.fromScale(0.56, 0.42), 0.3)
	piece("Cuff", UDim2.fromScale(0.3, 0.82), UDim2.fromScale(0.4, 0.14), 0.4)
	return parts
end

function TutorialHint.new()
	local self = setmetatable({}, TutorialHint)
	self.hint = nil
	self.kind = "SHOT"
	self.clock = 0
	self.nudgeUntil = -1
	self.misses = 0
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	self.anchor = create("Attachment", { Name = "TutorialHintAnchor" })
	self.fingerAnchor = create("Attachment", { Name = "TutorialFingerAnchor" })

	-- Ring + callout, anchored at the target.
	local gui = create("BillboardGui", {
		Name = "TutorialHint",
		Adornee = self.anchor,
		AlwaysOnTop = true,
		LightInfluence = 0,
		ClipsDescendants = false,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Enabled = false,
		Parent = playerGui,
	})
	self.gui = gui

	local target = create("Frame", {
		Name = "Target",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -2 * MARGIN, 1, -2 * MARGIN),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	self.target = target
	local fill = create("Frame", {
		Name = "Fill",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = GOLD,
		BackgroundTransparency = 0.82,
		Parent = target,
	})
	create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = fill })
	self.fill = fill
	circle(target, "Outline", INK, 6)
	local _, ring = circle(target, "Ring", GOLD, 3.5)
	self.ringStroke = ring
	local dot = create("Frame", {
		Name = "Dot",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.16, 0.16),
		BackgroundColor3 = GOLD,
		Parent = target,
	})
	create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = dot })
	create("UIStroke", { Color = INK, Thickness = 2, Parent = dot })
	self.dot = dot
	self.ripples = {}
	for i = 1, 2 do
		local ripple, stroke = circle(target, "Ripple" .. i, GOLD, 3)
		self.ripples[i] = { frame = ripple, stroke = stroke }
	end

	local bubble = create("Frame", {
		Name = "Callout",
		AnchorPoint = Vector2.new(0.5, 1),
		Size = UDim2.fromOffset(0, 40),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = NAVY,
		BackgroundTransparency = 0.05,
		ZIndex = 4,
		Parent = gui,
	})
	create("UICorner", { CornerRadius = UDim.new(0, 9), Parent = bubble })
	self.bubbleStroke = create("UIStroke", { Color = GOLD, Thickness = 2.5, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = bubble })
	create("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14), Parent = bubble })
	self.bubbleScale = create("UIScale", { Parent = bubble })
	self.label = create("TextLabel", {
		Size = UDim2.fromScale(0, 1),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		FontFace = FONT,
		TextSize = 24,
		TextColor3 = CREAM,
		Text = TEXT.Press,
		ZIndex = 5,
		Parent = bubble,
	})
	create("UIStroke", { Color = INK, Thickness = 2, Parent = self.label })
	self.bubble = bubble
	local tail = create("Frame", {
		Name = "Tail",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 1, 1),
		Size = UDim2.fromOffset(12, 12),
		Rotation = 45,
		BackgroundColor3 = NAVY,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = bubble,
	})
	self.tailStroke = create("UIStroke", { Color = GOLD, Thickness = 2.5, Parent = tail })
	self.popScale = 1

	-- Finger, in its own billboard so it can travel (the pass drag). Its anchor point is the fingertip.
	local fingerGui = create("BillboardGui", {
		Name = "TutorialFinger",
		Adornee = self.fingerAnchor,
		AlwaysOnTop = true,
		LightInfluence = 0,
		ClipsDescendants = false,
		ResetOnSpawn = false,
		Size = UDim2.fromOffset(FINGER_SIZE * 3, FINGER_SIZE * 3),
		Enabled = false,
		Parent = playerGui,
	})
	self.fingerGui = fingerGui
	local image = ImageLoader.get("Ui/Finger")
	local uiImages = Shared:FindFirstChild("Images") and Shared.Images:FindFirstChild("Ui")
	local tip = uiImages and (require(uiImages) :: any).FingerTip
	local finger
	if image then
		finger = create("ImageLabel", {
			Name = "Finger",
			AnchorPoint = if tip then Vector2.new(tip[1], tip[2]) else Vector2.new(0.5, 0.03),
			BackgroundTransparency = 1,
			ImageContent = image,
			Parent = fingerGui,
		})
	else
		finger = create("Frame", { Name = "Finger", AnchorPoint = Vector2.new(0.49, 0.03), BackgroundTransparency = 1, Parent = fingerGui })
		self.fingerParts = fallbackFinger(finger)
	end
	self.finger = finger
	self.fingerScale = create("UIScale", { Parent = finger })
	return self
end

-- kind: SHOT | PASS. hint from the server's tutorial episode:
--   SHOT { aimX, aimY, ringRadius, tapRadius, powerMin, powerMax }
--   PASS { start, target, ringRadius, tapRadius, powerMin, powerMax }
function TutorialHint:show(kind: string, hint)
	self.kind = kind
	self.hint = hint
	self.clock = 0
	self.nudgeUntil = -1
	self.misses = 0
	self.anchor.Parent = workspace.Terrain
	self.fingerAnchor.Parent = workspace.Terrain
	if kind == "PASS" then
		self.point = hint.target
		self.start = hint.start
		self.anchor.WorldPosition = hint.target + Vector3.new(0, CALLOUT_HEIGHT, 0)
		self.gui.Size = UDim2.fromOffset(2 * MARGIN, 2 * MARGIN)
		self.target.Visible = false -- the teammate's own ground ring pulses instead
	else
		self.point = ShotPhysics.aimToGoalPoint(hint.aimX, hint.aimY)
		self.start = nil
		self.anchor.WorldPosition = self.point
		local d = hint.ringRadius * 2
		self.gui.Size = UDim2.new(d, 2 * MARGIN, d, 2 * MARGIN)
		self.target.Visible = true
	end
	self.fingerAnchor.WorldPosition = self.start or self.point
	self.gui.Enabled = true
	self.fingerGui.Enabled = true
end

function TutorialHint:hide()
	self.hint = nil
	self.gui.Enabled = false
	self.fingerGui.Enabled = false
	self.anchor.Parent = nil
	self.fingerAnchor.Parent = nil
end

function TutorialHint:isActive(): boolean
	return self.hint ~= nil
end

-- A miss is ignored once with a nudge; after that anything counts (the guided attempt keeps the
-- hinted target anyway).
function TutorialHint:_judge(distance: number): boolean
	if distance <= self.hint.tapRadius then
		return true
	end
	self.misses += 1
	return self.misses > 1
end

-- SHOT: whether a press at this aim counts (distance on the goal plane, in studs).
function TutorialHint:accepts(aimX: number, aimY: number): boolean
	if not self.hint then
		return true
	end
	local p = ShotPhysics.aimToGoalPoint(aimX, aimY)
	return self:_judge((Vector3.new(p.X, p.Y, 0) - Vector3.new(self.point.X, self.point.Y, 0)).Magnitude)
end

-- PASS: whether a release at this ground point counts.
function TutorialHint:acceptsTarget(target: Vector3): boolean
	if not self.hint then
		return true
	end
	return self:_judge(Vector3.new(target.X - self.point.X, 0, target.Z - self.point.Z).Magnitude)
end

-- Pressed / released somewhere else: shake the finger and show the target again.
function TutorialHint:nudge()
	self.nudgeUntil = self.clock + 1.2
end

function TutorialHint:_setLabel(text: string, color: Color3)
	if self.label.Text ~= text then
		self.label.Text = text
		self.popScale = 1.15
	end
	self.label.TextColor3 = color
	self.bubbleStroke.Color = color
	self.tailStroke.Color = color
end

function TutorialHint:_setFinger(scale: number, alpha: number)
	self.fingerScale.Scale = scale
	if self.fingerParts then
		for _, part in self.fingerParts do
			part.BackgroundTransparency = alpha
			local stroke = part:FindFirstChildOfClass("UIStroke")
			if stroke then
				stroke.Transparency = alpha
			end
		end
	else
		self.finger.ImageTransparency = alpha
	end
end

-- Shot demo; returns the power to show on the bar (nil = leave it to the player).
function TutorialHint:_updateShot(holding: boolean, power: number, s: number, radius: number, pulse: number): (Vector2, number, number, number?, number)
	local hint = self.hint
	local fingerOffset, fingerScale, fingerAlpha, demoPower = Vector2.zero, 1, 0, nil
	local rippleT = (self.clock % 1.1) / 1.1
	local inZone = power >= hint.powerMin and power <= hint.powerMax
	if holding then
		fingerScale = 0.86
		if inZone then
			self:_setLabel(TEXT.Release, LIME)
			self.popScale = math.max(self.popScale, 1 + 0.08 * pulse)
		else
			self:_setLabel(TEXT.Wait, GOLD)
		end
	elseif self.clock < self.nudgeUntil then
		fingerOffset = Vector2.new(math.sin(self.clock * 40) * 10 * s * (self.nudgeUntil - self.clock), 0)
		self:_setLabel(TEXT.Missed, PINK)
	else
		local t = self.clock % SHOT_LOOP
		local start = Vector2.new(radius * 1.2 + 60 * s, radius * 1.4 + 90 * s)
		if t < ARRIVE then
			local k = easeOut(t / ARRIVE)
			fingerOffset = start:Lerp(Vector2.zero, k)
			fingerAlpha = 1 - k
			self:_setLabel(TEXT.Press, GOLD)
		elseif t < PRESS then
			fingerScale = 1 - 0.14 * easeOut((t - ARRIVE) / (PRESS - ARRIVE))
			rippleT = (t - ARRIVE) / 1.1
			self:_setLabel(TEXT.Press, GOLD)
		elseif t < RELEASE then
			fingerScale = 0.86
			rippleT = (t - ARRIVE) / 1.1
			demoPower = DEMO_POWER * (t - PRESS) / (RELEASE - PRESS)
			self:_setLabel(TEXT.Hold, GOLD)
		elseif t < FADE then
			local k = easeOut((t - RELEASE) / (FADE - RELEASE))
			fingerScale = 0.86 + 0.14 * k
			fingerOffset = Vector2.new(10 * s * k, -16 * s * k)
			fingerAlpha = k
			demoPower = DEMO_POWER
			self:_setLabel(TEXT.Release, LIME)
		else
			fingerAlpha = 1
			demoPower = 0
			self:_setLabel(TEXT.Press, GOLD)
		end
	end
	local accent = if holding and inZone then LIME else GOLD
	self.ringStroke.Color = accent
	self.fill.BackgroundColor3 = accent
	self.dot.BackgroundColor3 = accent
	self.fill.BackgroundTransparency = 0.86 - 0.1 * pulse
	for i, ripple in self.ripples do
		local k = (rippleT + (i - 1) * 0.5) % 1
		ripple.frame.Size = UDim2.fromScale(1 + k * 0.9, 1 + k * 0.9)
		ripple.stroke.Transparency = 0.2 + 0.8 * k
		ripple.stroke.Color = accent
	end
	self.fingerAnchor.WorldPosition = self.point
	return fingerOffset, fingerScale, fingerAlpha, demoPower, 0
end

-- Pass demo: press at the ball, drag to the teammate, let go.
function TutorialHint:_updatePass(holding: boolean, aimTarget: Vector3?, s: number): (Vector2, number, number, number?)
	local fingerScale, fingerAlpha, demoPower = 1, 0, nil
	local fingerOffset = Vector2.zero
	local start, point = self.start :: Vector3, self.point
	local ground = Vector3.new(point.X, 0, point.Z)
	local fullPower = Vector3.new(point.X - start.X, 0, point.Z - start.Z).Magnitude / PassConfig.Ball.MaxRange
	if holding then
		fingerAlpha = 1 -- the player's own finger is there now
		local near = aimTarget and Vector3.new(aimTarget.X - point.X, 0, aimTarget.Z - point.Z).Magnitude <= self.hint.tapRadius
		if near then
			self:_setLabel(TEXT.PassRelease, LIME)
		else
			self:_setLabel(TEXT.PassPress, GOLD)
		end
		self.fingerAnchor.WorldPosition = ground
	elseif self.clock < self.nudgeUntil then
		fingerOffset = Vector2.new(math.sin(self.clock * 40) * 10 * s * (self.nudgeUntil - self.clock), 0)
		self.fingerAnchor.WorldPosition = ground
		self:_setLabel(TEXT.PassMissed, PINK)
	else
		local t = self.clock % PASS_LOOP
		local at = start
		if t < P_ARRIVE then
			fingerAlpha = 1 - easeOut(t / P_ARRIVE)
			fingerOffset = Vector2.new(0, 40 * s * (1 - easeOut(t / P_ARRIVE)))
		elseif t < P_PRESS then
			fingerScale = 1 - 0.14 * easeOut((t - P_ARRIVE) / (P_PRESS - P_ARRIVE))
			demoPower = 0
		elseif t < P_DRAG then
			local k = easeInOut((t - P_PRESS) / (P_DRAG - P_PRESS))
			fingerScale = 0.86
			at = start:Lerp(ground, k)
			demoPower = fullPower * k
		elseif t < P_RELEASE then
			local k = easeOut((t - P_DRAG) / (P_RELEASE - P_DRAG))
			at = ground
			fingerScale = 0.86 + 0.14 * k
			fingerOffset = Vector2.new(0, -16 * s * k)
			fingerAlpha = k
			demoPower = fullPower
		else
			at = ground
			fingerAlpha = 1
			demoPower = 0
		end
		self.fingerAnchor.WorldPosition = Vector3.new(at.X, 0, at.Z)
		self:_setLabel(if t >= P_DRAG and t < P_RELEASE then TEXT.PassRelease else TEXT.PassPress, if t >= P_DRAG and t < P_RELEASE then LIME else GOLD)
	end
	return fingerOffset, fingerScale, fingerAlpha, demoPower
end

-- Call every frame with the HUD scale. aimTarget: the pass drop point while dragging.
-- Returns the demo power to show on the power bar while the player isn't holding.
function TutorialHint:update(dt: number, holding: boolean, power: number, uiScale: number, aimTarget: Vector3?): number?
	local hint = self.hint
	if not hint then
		return nil
	end
	self.clock += dt
	local s = uiScale
	self.popScale += (1 - self.popScale) * math.min(1, dt * 10)
	local pulse = 0.5 + 0.5 * math.sin(self.clock * 6)

	local radius = if self.kind == "SHOT" then math.max(12, self.target.AbsoluteSize.X / 2) else 0
	local fingerOffset, fingerScale, fingerAlpha, demoPower
	if self.kind == "PASS" then
		fingerOffset, fingerScale, fingerAlpha, demoPower = self:_updatePass(holding, aimTarget, s)
	else
		fingerOffset, fingerScale, fingerAlpha, demoPower = self:_updateShot(holding, power, s, radius, pulse)
	end

	self.bubble.Position = UDim2.new(0.5, 0, 0.5, -radius - 12 * s)
	self.bubbleScale.Scale = s * self.popScale

	local size = FINGER_SIZE * s
	self.fingerGui.Size = UDim2.fromOffset(size * 3, size * 3)
	self.finger.Size = UDim2.fromOffset(size, size)
	self.finger.Position = UDim2.new(0.5, fingerOffset.X, 0.5, fingerOffset.Y)
	self:_setFinger(fingerScale, fingerAlpha)
	return demoPower
end

return TutorialHint
