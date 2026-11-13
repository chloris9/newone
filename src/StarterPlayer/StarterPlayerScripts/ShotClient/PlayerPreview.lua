-- Your footballer on the pitch during career creation (the PlayerMain sheet, navy team kit). He
-- appears facing the camera (gold flash, sparkles), then turns
-- round to show the surname and number on his back; every change turns him to the back again.
-- Everything here is local to this client; CareerMenu drives it and owns the camera.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShotConfig = require(Shared:WaitForChild("ShotConfig"))
local CareerConfig = require(Shared:WaitForChild("CareerConfig"))
local FigureBuilder = require(Shared:WaitForChild("FigureBuilder"))
local FigureAnimator = require(script.Parent:WaitForChild("FigureAnimator"))
local UiKit = require(script.Parent:WaitForChild("UiKit"))

local SCALE = ShotConfig.Goalkeeper.ModelScale -- same size as the training players
-- He stands between the shot spot and the camera, with the goal and the stand behind him.
local STAGE = Vector3.new(0, 0, 56)
-- Camera offset from his feet and the point it looks at, shifted left so he stands in the right
-- half of the screen, next to the creation form.
local FRAMINGS = {
	CREATE = { offset = Vector3.new(-4.6, 4.4, 17), look = Vector3.new(-4.6, 3.7, 0), fov = 40 },
}
local FADE_IN = 0.55
local FRONT_HOLD = 1.5 -- seconds facing the camera before the first turn (CREATE)
local TURN_TIME = 0.9

local PlayerPreview = {}
PlayerPreview.__index = PlayerPreview

local function smooth(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

local function facingFor(angle: number): Vector3
	return Vector3.new(math.sin(angle), 0, math.cos(angle))
end

-- Angle at which he faces the camera of a framing.
local function frontAngle(framing): number
	return math.atan2(framing.offset.X, framing.offset.Z)
end

local function makePart(props: { [string]: any }): Part
	props.Anchored = true
	props.CanCollide = false
	props.CanQuery = false
	props.CanTouch = false
	props.CastShadow = props.CastShadow or false
	props.TopSurface = Enum.SurfaceType.Smooth
	props.BottomSurface = Enum.SurfaceType.Smooth
	return UiKit.create("Part", props)
end

function PlayerPreview.new()
	local self = setmetatable({}, PlayerPreview)
	self.folder = UiKit.create("Folder", { Name = "CareerPreview" })
	self.visible = false
	self.clock = 0
	self.animator = nil
	self.framing = FRAMINGS.CREATE
	self.front = frontAngle(self.framing)
	self.angle = self.front
	self.turnFrom, self.turnTo, self.turnStart = self.angle, self.angle, -math.huge
	self.facingBack = false
	self.introAt = nil :: number?
	self.appearStart = 0
	self.fadeParts = {}
	self.fadeGuis = {}

	-- Showcase lighting: warm key light from the camera side, violet rim from behind.
	local key = makePart({ Name = "KeyLight", Size = Vector3.one * 0.2, Transparency = 1, Position = STAGE + Vector3.new(-2, 8, 9), Parent = self.folder })
	UiKit.create("PointLight", { Color = UiKit.rgb(255, 232, 200), Brightness = 1.6, Range = 18, Shadows = false, Parent = key })
	local rim = makePart({ Name = "RimLight", Size = Vector3.one * 0.2, Transparency = 1, Position = STAGE + Vector3.new(2.5, 8, -4), Parent = self.folder })
	UiKit.create("PointLight", { Color = UiKit.GLOW, Brightness = 3, Range = 13, Shadows = false, Parent = rim })

	-- Thin gold ring under his feet (a flat SurfaceGui, so it stays a clean outline).
	local ringPart = makePart({ Name = "Ring", Size = Vector3.new(6.4, 0.05, 6.4), Transparency = 1, Position = STAGE + Vector3.new(0, 0.05, 0), Parent = self.folder })
	local ringGui = UiKit.create("SurfaceGui", { Face = Enum.NormalId.Top, SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud, PixelsPerStud = 40, LightInfluence = 0, Parent = ringPart })
	local ring = UiKit.frame({ Size = UDim2.fromScale(1, 1), BackgroundColor3 = UiKit.GLOW, BackgroundTransparency = 0.88, Parent = ringGui })
	UiKit.corner(ring)
	self.ringStroke = UiKit.stroke(ring, UiKit.GOLD, 6, 0.2)

	self.flash = makePart({
		Name = "Flash",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.05, 2, 2),
		CFrame = CFrame.new(STAGE + Vector3.new(0, 0.07, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Color = UiKit.GOLD,
		Material = Enum.Material.Neon,
		Transparency = 1,
		Parent = self.folder,
	})
	local sparkleCarrier = makePart({ Name = "Sparkles", Size = Vector3.one * 0.2, Transparency = 1, Position = STAGE + Vector3.new(0, 4.2, 0), Parent = self.folder })
	self.sparkles = UiKit.create("ParticleEmitter", {
		Enabled = false,
		Color = ColorSequence.new(UiKit.GOLD_LIGHT, UiKit.GOLD),
		LightEmission = 1,
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 0) }),
		Transparency = NumberSequence.new(0.1),
		Lifetime = NumberRange.new(0.6, 1.1),
		Speed = NumberRange.new(7, 14),
		SpreadAngle = Vector2.new(180, 180),
		Acceleration = Vector3.new(0, -10, 0),
		Drag = 2,
		Parent = sparkleCarrier,
	})
	return self
end

-- Where the camera looks at him from, its field of view and how far he is.
function PlayerPreview.cameraTarget(mode: string): (CFrame, number, number)
	local framing = FRAMINGS[mode] or FRAMINGS.CREATE
	return CFrame.lookAt(STAGE + framing.offset, STAGE + framing.look), framing.fov, framing.offset.Magnitude
end

-- The player from the PlayerMain sheet, in the team's navy kit with the chosen number and surname
-- printed by FigureBuilder. The back number pops when it changes.
local NAVY = UiKit.rgb(26, 36, 110)
local PLAYER_KIT = {
	skin = CareerConfig.Skin,
	hair = CareerConfig.Hair,
	shirt = NAVY,
	shorts = NAVY,
	socks = NAVY,
	boots = UiKit.rgb(236, 232, 244),
	number = 10,
}

function PlayerPreview:_build()
	local model, rootHeight = FigureBuilder.build("CareerPlayer", PLAYER_KIT, SCALE, "PlayerMain")
	self.fadeParts = {}
	self.fadeGuis = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CastShadow = true
			table.insert(self.fadeParts, d)
		elseif d:IsA("Decal") then
			table.insert(self.fadeParts, d)
		elseif d:IsA("SurfaceGui") then
			table.insert(self.fadeGuis, d)
		end
	end
	self.backNumber = model:FindFirstChild("BackNumber", true) :: TextLabel
	self.backName = model:FindFirstChild("Surname", true) :: TextLabel
	self.numberPop = UiKit.create("UIScale", { Parent = self.backNumber })
	model.Parent = self.folder
	self.animator = FigureAnimator.new(model, rootHeight, SCALE)
end

function PlayerPreview:_setFade(amount: number)
	for _, part in self.fadeParts do
		part.LocalTransparencyModifier = amount
	end
	for _, gui in self.fadeGuis do
		gui.Enabled = amount < 0.5
	end
end

function PlayerPreview:_turn(delta: number)
	self.turnFrom = self.angle
	self.turnTo += delta
	self.turnStart = self.clock
end

function PlayerPreview:showBack()
	if not self.facingBack then
		self.facingBack = true
		self:_turn(math.pi)
	end
end

function PlayerPreview:showFront()
	if self.facingBack then
		self.facingBack = false
		self:_turn(math.pi)
	end
end

function PlayerPreview:_appear(mode: string)
	if not self.animator then
		self:_build()
	end
	self.mode = mode
	self.framing = FRAMINGS[mode]
	self.front = frontAngle(self.framing)
	self.folder.Parent = workspace
	self.visible = true
	self.angle, self.turnFrom, self.turnTo, self.turnStart = self.front, self.front, self.front, -math.huge
	self.facingBack = false
	self.animator:place(STAGE, facingFor(self.front))
	self.animator:play(nil)
	self.appearStart = self.clock
	self:_setFade(1)

	self.flash.Size = Vector3.new(0.05, 2, 2)
	self.flash.Transparency = 0.1
	TweenService:Create(self.flash, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(0.05, 15, 15), Transparency = 1 }):Play()
	task.delay(0.12, function()
		if self.visible then
			self.sparkles:Emit(36)
		end
	end)
end

-- Player creation: appears facing the camera, then turns to show the back.
function PlayerPreview:show(lastName: string, number: number?)
	self:_appear("CREATE")
	self.introAt = self.clock + FRONT_HOLD
	self:setIdentity(lastName, number, true)
end

-- Updates the shirt prints. Unless `quiet`, he turns to show the back and the number pops.
function PlayerPreview:setIdentity(lastName: string, number: number?, quiet: boolean?)
	if not self.animator then
		return
	end
	local surname = CareerConfig.upper(lastName)
	local digits = if number then tostring(number) else ""
	local changed = self.backName.Text ~= surname or self.backNumber.Text ~= digits
	FigureBuilder.setPrints(self.animator.model, digits, surname)
	if quiet or not changed or self.introAt then
		return
	end
	self:showBack()
	self.numberPop.Scale = 1.3
	TweenService:Create(self.numberPop, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

-- Contract signed: turns to the camera and gives a short nod.
function PlayerPreview:celebrate()
	self.introAt = nil
	self:showFront()
	if self.animator then
		self.animator:play("NOD")
	end
	self.sparkles:Emit(24)
end

function PlayerPreview:hide()
	self.visible = false
	self.mode = nil
	self.folder.Parent = nil
	if self.animator then
		self.animator:play(nil)
	end
end

function PlayerPreview:update(dt: number)
	if not (self.visible and self.animator) then
		return
	end
	self.clock += dt
	self:_setFade(1 - smooth((self.clock - self.appearStart) / FADE_IN))
	if self.introAt and self.clock >= self.introAt then
		self.introAt = nil
		self:showBack()
	end
	self.angle = self.turnFrom + (self.turnTo - self.turnFrom) * smooth((self.clock - self.turnStart) / TURN_TIME)
	self.animator:place(STAGE, facingFor(self.angle))
	self.animator:update(dt)
	self.ringStroke.Transparency = 0.15 + 0.3 * (0.5 + 0.5 * math.sin(self.clock * 2.4))
end

return PlayerPreview
