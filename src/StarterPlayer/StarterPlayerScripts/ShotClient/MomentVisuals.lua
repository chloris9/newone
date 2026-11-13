-- 3D side of a match moment (MomentPhysics), everything local to this client:
--   studio()         the broadcast camera over the blurred stadium while the commentator talks;
--   begin(layout)    a step of your moment: the intro (#28 passes to you, you carry it, or the
--                    one-two comes back), then the decision in slow motion: drag an arrow from the
--                    ball (onAim), then the strike screen: a close-up of the ball, tap where to hit
--                    it (onStrike). Open teammates show a ball bubble; pressers close in.
--   playPass / tackle / handOffShot / celebrate replay what the server decided.
-- Shots themselves (flight, keeper, net) are ShotVisuals'; handOffShot lets its camera take over.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShotConfig = require(Shared:WaitForChild("ShotConfig"))
local MomentPhysics = require(Shared:WaitForChild("MomentPhysics"))
local FigureBuilder = require(Shared:WaitForChild("FigureBuilder"))
local FigureAnimator = require(script.Parent:WaitForChild("FigureAnimator"))

local Config = MomentPhysics.Config
local BALL_RADIUS = ShotConfig.Ball.Radius
local SCALE = ShotConfig.Goalkeeper.ModelScale
local SLOW = Config.SlowMo
local MAX_DEFENDERS = 3
local DASHES = 16
local HEAD_BARS = 8
local CAMERA_BLEND = 0.8
local STRIKE_BLEND = 0.35
local DECIDE_FOV = 50
local CAMERA_PITCH = 40 -- degrees below the horizon on the pitch view
local STRIKE_FOV = 38
local STRIKE_DISTANCE = 5.4 -- camera behind the ball on the strike screen
-- Shots in a moment: high behind the shooter, so the goal stays in view over everyone's heads.
local SHOT_FOV = 50
local SHOT_BACK = 12
local SHOT_HEIGHT = 11
local GOAL_MOUTH = Vector3.new(0, 4, 0)
-- Players between the camera and the play turn see-through.
local FADE = 0.7
local FADE_RADIUS = 3.2
local FADE_NEAR = 9
local MATE_TARGET_RADIUS = 6 -- the arrow "points at" a teammate this close to its end

local rgb = Color3.fromRGB
local WHITE = Color3.new(1, 1, 1)
local GOLD = rgb(255, 191, 31)
local LIME = rgb(150, 240, 60)
local LILAC = rgb(190, 168, 255)
local RED = rgb(255, 45, 85)
local ARROW_RED = rgb(255, 70, 40)
local SKIN = rgb(214, 132, 82)
local HAIR = rgb(52, 32, 26)
-- Kits are painted on from the character sheets; these colours only show if images are unavailable.
local NAVY = rgb(26, 36, 110)
local TEAM_KIT = { skin = SKIN, shirt = NAVY, shorts = NAVY, socks = NAVY, boots = rgb(236, 232, 244), hair = HAIR }
local BLACK = rgb(24, 18, 26)
local OPPONENT_KIT = { skin = SKIN, shirt = BLACK, shorts = BLACK, socks = BLACK, boots = rgb(236, 232, 244), hair = HAIR, print = rgb(245, 245, 245) }
local Images = Shared:WaitForChild("Images")
local DEFENDER_SHEET = if Images:FindFirstChild("RivalPlain") then "RivalPlain" else "Rival9"

local MomentVisuals = {}
MomentVisuals.__index = MomentVisuals

local function create(className: string, props: { [string]: any }): any
	local inst = Instance.new(className)
	local parent = props.Parent
	for key, value in props do
		if key ~= "Parent" then
			inst[key] = value
		end
	end
	inst.Parent = parent
	return inst
end

local function makePart(props: { [string]: any }): Part
	props.Anchored = true
	props.CanCollide = false
	props.CanQuery = false
	props.CanTouch = false
	props.CastShadow = props.CastShadow or false
	props.Material = props.Material or Enum.Material.SmoothPlastic
	return create("Part", props)
end

local function groundCircle(parent: Instance, name: string, radius: number, color: Color3, fill: number)
	local part = makePart({ Name = name, Size = Vector3.new(radius * 2, 0.05, radius * 2), Transparency = 1, Parent = parent })
	local gui = create("SurfaceGui", { Face = Enum.NormalId.Top, LightInfluence = 0, SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud, PixelsPerStud = 24, Parent = part })
	local circle = create("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, -8, 1, -8), BackgroundColor3 = color, BackgroundTransparency = fill, Parent = gui })
	create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = circle })
	local stroke = create("UIStroke", { Color = color, Thickness = 5, Parent = circle })
	return { part = part, frame = circle, stroke = stroke }
end

local function icosahedronDirections(): { Vector3 }
	local phi = (1 + math.sqrt(5)) / 2
	local dirs = {}
	for _, a in { -1, 1 } do
		for _, b in { -phi, phi } do
			table.insert(dirs, Vector3.new(0, a, b).Unit)
			table.insert(dirs, Vector3.new(a, b, 0).Unit)
			table.insert(dirs, Vector3.new(b, 0, a).Unit)
		end
	end
	return dirs
end

local function trackAt(track: { Vector3 }, step: number, t: number): Vector3
	local f = math.max(t, 0) / step
	local i = math.floor(f)
	if i >= #track - 1 then
		return track[#track]
	end
	return track[i + 1]:Lerp(track[i + 2], f - i)
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function unit(v: Vector3, fallback: Vector3): Vector3
	return if v.Magnitude > 1e-4 then v.Unit else fallback
end

local function smooth(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- Where you stand with the ball on your right foot.
local function standFor(ball: Vector3, facing: Vector3): Vector3
	return flat(ball) - facing * 1.5 - facing:Cross(Vector3.yAxis) * 0.7
end

---------------------------------------------------------------- construction

function MomentVisuals.new()
	local self = setmetatable({}, MomentVisuals)
	self.active = false
	self.phase = "IDLE"
	self.token = 0
	self.cameraMode = "NONE" -- STUDIO | PITCH | STRIKE | FOCUS | NONE (someone else has it)
	self.ballRotation = CFrame.identity
	self.ballPosition = Vector3.new(0, -50, 0)
	-- Callbacks (ShotClient)
	self.onReady = nil :: ((number) -> ())?
	self.onAim = nil :: ((any) -> ())? -- aim info while dragging, nil when not
	self.onStrikeStart = nil :: (() -> ())?
	self.onStrikeTimer = nil :: ((number) -> ())?
	self.onReticle = nil :: ((Vector2?) -> ())?
	self.onStrike = nil :: ((number, number, number, number, number, number) -> ())?
	self.onTimer = nil :: ((number?) -> ())?

	local folder = create("Folder", { Name = "MomentVisuals" })
	self.folder = folder

	local ballModel = create("Model", { Name = "Ball", Parent = folder })
	local shell = makePart({ Name = "Shell", Shape = Enum.PartType.Ball, Size = Vector3.one * BALL_RADIUS * 2, Color = WHITE, CastShadow = true, Parent = ballModel })
	self.ballParts = { { shell, CFrame.identity } }
	for _, dir in icosahedronDirections() do
		local reference = if math.abs(dir.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis
		-- Small and sunk in: the close-up on the strike screen must still read as a round ball.
		local patch = makePart({ Name = "Panel", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.06, BALL_RADIUS * 0.5, BALL_RADIUS * 0.5), Color = rgb(28, 18, 48), Parent = ballModel })
		table.insert(self.ballParts, { patch, CFrame.fromMatrix(dir * BALL_RADIUS * 0.972, dir, dir:Cross(reference).Unit) })
	end

	local function figure(name: string, kit, sheet: string, number: number?)
		local dressed = table.clone(kit)
		dressed.number = number
		local model, rootHeight = FigureBuilder.build(name, dressed, SCALE, sheet)
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") then
				part.CastShadow = true
			end
		end
		model.Parent = folder
		local animator = FigureAnimator.new(model, rootHeight, SCALE)
		animator.hideParts = {}
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") or d:IsA("Decal") then
				table.insert(animator.hideParts, d)
			elseif d:IsA("SurfaceGui") then
				table.insert(animator.hideParts, d)
			end
		end
		return animator
	end
	self.me = figure("You", TEAM_KIT, "PlayerMain", 10)
	self.mates = { figure("Mate7", TEAM_KIT, "Teammate7"), figure("Mate28", TEAM_KIT, "Teammate28") }
	self.defenders = {}
	for i = 1, MAX_DEFENDERS do
		self.defenders[i] = figure("Defender" .. i, OPPONENT_KIT, DEFENDER_SHEET, if DEFENDER_SHEET == "RivalPlain" then 3 + i else nil)
	end

	-- Ground markers.
	self.meRing = groundCircle(folder, "YouRing", 2.6, LIME, 0.75)
	self.mateRings = {}
	for i = 1, 2 do
		self.mateRings[i] = groundCircle(folder, "MateRing" .. i, 3, LILAC, 0.85)
	end
	self.dangerRings = {}
	for i = 1, MAX_DEFENDERS do
		self.dangerRings[i] = groundCircle(folder, "Danger" .. i, Config.TackleReach + 0.6, RED, 0.8)
	end

	-- The arrow: a dashed shaft and a solid head, flat on the grass.
	self.dashes = {}
	for i = 1, DASHES do
		self.dashes[i] = makePart({ Name = "Dash", Size = Vector3.new(1.1, 0.12, 2), Color = ARROW_RED, Material = Enum.Material.Neon, Transparency = 1, Parent = folder })
	end
	self.headBars = {}
	for i = 1, HEAD_BARS do
		self.headBars[i] = makePart({ Name = "Head", Size = Vector3.new(1, 0.12, 0.7), Color = ARROW_RED, Material = Enum.Material.Neon, Transparency = 1, Parent = folder })
	end

	-- Ball bubbles over teammates who want it.
	self.bubbles = {}
	for i, mate in self.mates do
		local head = mate.model:FindFirstChild("Head")
		local gui = create("BillboardGui", { Name = "Bubble", Adornee = head, Size = UDim2.fromOffset(46, 52), StudsOffset = Vector3.new(0, 2.6, 0), AlwaysOnTop = true, LightInfluence = 0, Enabled = false, Parent = folder })
		local bubble = create("Frame", { Size = UDim2.fromOffset(46, 42), BackgroundColor3 = WHITE, BorderSizePixel = 0, Parent = gui })
		create("UICorner", { CornerRadius = UDim.new(0, 10), Parent = bubble })
		create("UIStroke", { Color = rgb(18, 6, 31), Thickness = 2.5, Parent = bubble })
		create("TextLabel", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "⚽", TextScaled = true, Parent = bubble })
		local tail = create("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(16, 43), Size = UDim2.fromOffset(12, 12), Rotation = 45, BackgroundColor3 = WHITE, BorderSizePixel = 0, ZIndex = 0, Parent = gui })
		create("UIStroke", { Color = rgb(18, 6, 31), Thickness = 2.5, Parent = tail })
		self.bubbles[i] = gui
	end

	-- Slow motion and the studio look.
	self.grade = create("ColorCorrectionEffect", { Name = "MomentGrade", Enabled = true, Saturation = 0, Contrast = 0, TintColor = WHITE, Parent = Lighting })
	self.blur = create("BlurEffect", { Name = "StudioBlur", Enabled = false, Size = 0, Parent = Lighting })

	UserInputService.InputBegan:Connect(function(input, processed)
		self:_onInputBegan(input, processed)
	end)
	UserInputService.InputChanged:Connect(function(input)
		self:_onInputChanged(input)
	end)
	UserInputService.InputEnded:Connect(function(input)
		self:_onInputEnded(input)
	end)
	return self
end

function MomentVisuals:setPlayer(number: number, surname: string)
	FigureBuilder.setPrints(self.me.model, number, surname)
end

local function applyLook(animator)
	local hidden = animator.hidden
	local fade = animator.fade or 0
	for _, part in animator.hideParts do
		if part:IsA("SurfaceGui") then
			part.Enabled = not hidden and fade < 0.3
		else
			part.LocalTransparencyModifier = if hidden then 1 else fade
		end
	end
end

local function setHidden(animator, hidden: boolean)
	if animator.hidden == hidden then
		return
	end
	animator.hidden = hidden
	applyLook(animator)
end

local function setFade(animator, fade: number)
	if math.abs((animator.fade or 0) - fade) < 0.01 then
		return
	end
	animator.fade = fade
	if not animator.hidden then
		applyLook(animator)
	end
end

-- Distance from p to the segment a-b, and how far along it p lies (0..1).
local function segmentDistance(p: Vector3, a: Vector3, b: Vector3): (number, number)
	local ab = b - a
	local t = math.clamp((p - a):Dot(ab) / math.max(ab:Dot(ab), 1e-6), 0, 1)
	return (p - (a + ab * t)).Magnitude, t
end

function MomentVisuals:_setBall(position: Vector3)
	local base = CFrame.new(position) * self.ballRotation
	for _, entry in self.ballParts do
		entry[1].CFrame = base * entry[2]
	end
	self.ballPosition = position
end

function MomentVisuals:_moveBall(position: Vector3)
	local moved = position - self.ballPosition
	if moved.Magnitude > 1e-4 and moved.Magnitude < 20 then
		local ground = flat(moved)
		if ground.Magnitude > 1e-4 then
			self.ballRotation = CFrame.fromAxisAngle(Vector3.yAxis:Cross(ground.Unit), ground.Magnitude / BALL_RADIUS) * self.ballRotation
		end
	end
	self:_setBall(position)
end

function MomentVisuals:hideBall()
	self:_setBall(Vector3.new(0, -50, 0))
end

local function placeRing(ring, position: Vector3)
	ring.part.CFrame = CFrame.new(position.X, 0.06, position.Z)
end

function MomentVisuals:_grade(slow: boolean)
	TweenService:Create(self.grade, TweenInfo.new(0.35), {
		Saturation = if slow then -0.3 else 0,
		Contrast = if slow then 0.1 else 0,
		TintColor = if slow then rgb(225, 232, 255) else WHITE,
	}):Play()
end

function MomentVisuals:_blendCamera(mode: string, duration: number?)
	local camera = workspace.CurrentCamera
	self.cameraMode = mode
	self.blendFrom, self.blendFov, self.blendT = camera.CFrame, camera.FieldOfView, 0
	self.blendTime = duration or CAMERA_BLEND
end

---------------------------------------------------------------- studio and enter / exit

-- Between moments: a slow broadcast shot over the stadium behind the panels.
function MomentVisuals:studio()
	self.token += 1
	self.phase = "STUDIO"
	self.active = false
	self.folder.Parent = nil
	self:_clearAim()
	self:_grade(false)
	self.blur.Enabled = true
	TweenService:Create(self.blur, TweenInfo.new(0.5), { Size = 14 }):Play()
	self.studioClock = 0
	self:_blendCamera("STUDIO", 0.6)
end

function MomentVisuals:exit()
	self.token += 1
	self.phase = "IDLE"
	self.active = false
	self.folder.Parent = nil
	self.cameraMode = "NONE"
	self.blur.Enabled = false
	self.blur.Size = 0
	self:_grade(false)
	self:_clearAim()
end

---------------------------------------------------------------- a step of the moment

-- New step: everyone to their marks, the intro, then the decision (onReady fires with the step).
function MomentVisuals:begin(layout)
	local previous = self.layout
	self.token += 1
	self.layout = layout
	self.active = true
	self.folder.Parent = workspace
	self.blur.Enabled = false
	self.blur.Size = 0
	self.phase = "INTRO"
	self.clock = 0
	self.decision = 0
	self.replay = nil
	self.tackled = false
	self.aim = nil
	self.dragging = nil
	self.intro = MomentPhysics.intro(layout)
	self.ballRotation = CFrame.identity
	for _, figure in self:_figures() do
		setHidden(figure, false)
	end
	local toGoal = layout.toGoal
	local carrier = layout.carrier

	-- Where everyone starts the intro.
	self.introFrom = {}
	if layout.kind == "ONE_TWO" and previous then
		-- You run on from where you were; defenders recover to their new spots.
		self.introFrom.me = self.me.position
		self.introBallFrom = layout.passerFrom
		for i, defender in self.defenders do
			self.introFrom[defender] = defender.position
		end
		self.me:play(nil)
	else
		if layout.kind == "RECEIVE" then
			self.me:place(standFor(carrier, toGoal), flat(layout.passerFrom - carrier))
			self.introBallFrom = layout.passerFrom + unit(flat(carrier - layout.passerFrom), toGoal) * 1.6
		else
			local from = carrier - toGoal * 7
			self.me:place(standFor(from, toGoal), toGoal)
			self.introBallFrom = from
		end
		self.introFrom.me = self.me.position
		for i, defender in self.defenders do
			local spec = layout.defenders[i]
			if spec then
				defender:place(spec.from, flat(carrier - spec.from))
			end
			self.introFrom[defender] = spec and spec.from
		end
	end
	self.me:play(nil)
	self:_setBall(flat(self.introBallFrom) + Vector3.new(0, BALL_RADIUS, 0))
	for i, mate in self.mates do
		local spec = layout.teammates[i]
		mate:play(nil)
		if layout.kind ~= "ONE_TWO" or i ~= layout.passer then
			if layout.kind ~= "ONE_TWO" then
				mate:place(spec.from, flat(carrier - spec.from))
			end
		end
		self.introFrom[mate] = mate.position
	end
	if layout.passer and layout.passerFrom then
		-- The passer stands behind the ball, about to play it.
		local passer = self.mates[layout.passer]
		local dir = unit(flat(carrier - layout.passerFrom), toGoal)
		local spot = flat(self.introBallFrom) - dir * 1.5 - dir:Cross(Vector3.yAxis) * 0.7
		if layout.kind ~= "ONE_TWO" then
			passer:place(spot, dir)
		end
		self.introFrom[passer] = passer.position
	end
	for i, defender in self.defenders do
		local spec = layout.defenders[i]
		defender.model.Parent = if spec then self.folder else nil
		if spec and spec.number and DEFENDER_SHEET == "RivalPlain" then
			FigureBuilder.setPrints(defender.model, spec.number, "")
		end
		defender:play(nil)
	end
	for i, ring in self.dangerRings do
		ring.part.Parent = nil
	end
	for i, ring in self.mateRings do
		ring.part.Parent = self.folder
	end
	self.meRing.part.Parent = self.folder
	self:_clearAim()
	self:_grade(false)
	if self.cameraMode ~= "PITCH" then
		self:_blendCamera("PITCH")
	end
	self.lookAt = nil
	return self.intro
end

function MomentVisuals:_figures()
	local list = { self.me, self.mates[1], self.mates[2] }
	for _, defender in self.defenders do
		table.insert(list, defender)
	end
	return list
end

function MomentVisuals:isDeciding(): boolean
	return self.phase == "DECIDE"
end

-- 1 = plenty of time, 0 = the tackle; nil outside the decision.
function MomentVisuals:timeLeft(): number?
	if self.phase ~= "DECIDE" or not self.layout then
		return nil
	end
	return 1 - self.decision / self.layout.tackleTime
end

---------------------------------------------------------------- the arrow

local function screenToGround(position: Vector3): Vector3?
	local camera = workspace.CurrentCamera
	local ray = camera:ScreenPointToRay(position.X, position.Y)
	if ray.Direction.Y > -1e-4 then
		return nil
	end
	return ray.Origin + ray.Direction * (-ray.Origin.Y / ray.Direction.Y)
end

function MomentVisuals:_clearAim()
	for _, part in self.dashes do
		part.Transparency = 1
	end
	for _, part in self.headBars do
		part.Transparency = 1
	end
	self.aimInfo = nil
	if self.onAim then
		self.onAim(nil)
	end
end

-- What the arrow ending at `target` means: SHOT, PASS to a teammate, PASS into space, or SHORT.
function MomentVisuals:_aimInfo(target: Vector3)
	local layout = self.layout
	local carrier = layout.carrier
	local length = flat(target - carrier).Magnitude
	if length < Config.MinArrow then
		return { kind = "SHORT", target = target, length = length }
	end
	if MomentPhysics.classify(layout, target) == "SHOT" then
		return { kind = "SHOT", target = target, length = length, blocked = MomentPhysics.laneBlocker(layout, target, self.decision) ~= nil }
	end
	local best, bestDistance = nil, MATE_TARGET_RADIUS
	for i in self.mates do
		local at = MomentPhysics.mateAt(layout, i, self.decision)
		local d = flat(at - target).Magnitude
		if d < bestDistance then
			best, bestDistance = i, d
		end
	end
	return { kind = if best then "MATE" else "SPACE", mate = best, number = best and layout.teammates[best].number, open = best and MomentPhysics.isOpen(layout, best, self.decision), target = target, length = length }
end

function MomentVisuals:_drawArrow(info)
	local carrier = self.layout.carrier
	local delta = flat(info.target - carrier)
	local length = delta.Magnitude
	if length < 1e-3 then
		self:_clearAim()
		return
	end
	local dir = delta / length
	local color = if info.kind == "SHOT" then (if info.blocked then rgb(255, 160, 40) else GOLD) elseif info.kind == "MATE" then (if info.open then LIME else rgb(255, 160, 40)) elseif info.kind == "SHORT" then LILAC else ARROW_RED
	local headLength = math.min(5, length * 0.45)
	local shaft = length - headLength
	local start = carrier + dir * 1.4
	local count = math.clamp(math.floor(shaft / 3.1), 0, DASHES)
	for i, part in self.dashes do
		if i <= count then
			local center = start + dir * ((i - 0.5) * (shaft - 1.4) / count)
			part.CFrame = CFrame.lookAt(Vector3.new(center.X, 0.14, center.Z), Vector3.new(center.X, 0.14, center.Z) + dir)
			part.Size = Vector3.new(1.1, 0.12, math.min(2, (shaft - 1.4) / count * 0.62))
			part.Color = color
			part.Transparency = 0.1
		else
			part.Transparency = 1
		end
	end
	-- The head: bars across the arrow, wide at the back and narrow at the tip.
	local headWidth = math.min(5, 1.6 + length * 0.12)
	for i, part in self.headBars do
		local k = (i - 0.5) / HEAD_BARS
		local center = carrier + dir * (shaft + headLength * k)
		part.CFrame = CFrame.lookAt(Vector3.new(center.X, 0.15, center.Z), Vector3.new(center.X, 0.15, center.Z) + dir)
		part.Size = Vector3.new(math.max(0.3, headWidth * (1 - k)), 0.12, headLength / HEAD_BARS + 0.05)
		part.Color = color
		part.Transparency = 0.05
	end
	self.aimInfo = info
	if self.onAim then
		self.onAim(info)
	end
end

---------------------------------------------------------------- input

local function isPress(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

function MomentVisuals:_onInputBegan(input: InputObject, processed: boolean)
	if processed or not isPress(input) then
		return
	end
	if self.phase == "DECIDE" and not self.dragging then
		self.dragging = input
		local target = screenToGround(input.Position)
		if target then
			self:_drawArrow(self:_aimInfo(target))
		end
	elseif self.phase == "STRIKE" then
		self:_tryStrike(input.Position)
	end
end

function MomentVisuals:_onInputChanged(input: InputObject)
	if self.phase == "DECIDE" and self.dragging then
		local moving = input.UserInputType == Enum.UserInputType.MouseMovement or (input.UserInputType == Enum.UserInputType.Touch and input == self.dragging)
		if moving then
			local target = screenToGround(input.Position)
			if target then
				local carrier = self.layout.carrier
				local delta = flat(target - carrier)
				if delta.Magnitude > Config.MaxArrow then
					target = carrier + delta.Unit * Config.MaxArrow
				end
				self:_drawArrow(self:_aimInfo(target))
			end
		end
	elseif self.phase == "STRIKE" then
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			local hit = self:_ballHit(input.Position)
			if self.onReticle then
				self.onReticle(if hit then Vector2.new(input.Position.X, input.Position.Y) else nil)
			end
		end
	end
end

function MomentVisuals:_onInputEnded(input: InputObject)
	if self.phase ~= "DECIDE" or not self.dragging then
		return
	end
	local active = self.dragging
	local isMouse = input.UserInputType == Enum.UserInputType.MouseButton1 and active.UserInputType == Enum.UserInputType.MouseButton1
	if not (isMouse or input == active) then
		return
	end
	self.dragging = nil
	local info = self.aimInfo
	if not info or info.kind == "SHORT" then
		self:_clearAim()
		return
	end
	self:_startStrike(info)
end

---------------------------------------------------------------- the strike screen

function MomentVisuals:_startStrike(info)
	self.phase = "STRIKE"
	self.aimTime = self.decision
	self.strikeInfo = info
	self.strikeClock = 0
	local carrier = self.layout.carrier
	local dir = unit(flat(info.target - carrier), self.layout.toGoal)
	self.strikeDir = dir
	-- The ball fills the middle of the screen; you (behind it) are hidden.
	local ball = carrier + Vector3.new(0, BALL_RADIUS, 0)
	self:_setBall(ball)
	self.ballRotation = CFrame.identity
	self.strikeCamera = CFrame.lookAt(ball - dir * STRIKE_DISTANCE + Vector3.new(0, 0.9, 0), ball + Vector3.new(0, 0.15, 0))
	-- Only the ball and the stadium, as in the reference: everyone is hidden for the close-up.
	for _, figure in self:_figures() do
		setHidden(figure, true)
	end
	for _, b in self.bubbles do
		b.Enabled = false
	end
	for _, ring in self.dangerRings do
		ring.part.Parent = nil
	end
	self.meRing.part.Parent = nil
	for _, ring in self.mateRings do
		ring.part.Parent = nil
	end
	self:_clearAim()
	self:_blendCamera("STRIKE", STRIKE_BLEND)
	if self.onStrikeStart then
		self.onStrikeStart()
	end
end

-- Screen point -> where on the ball (x right, y up, -1..1 as seen by the camera), or nil if it
-- missed the ball.
function MomentVisuals:_ballHit(position: Vector3): (number?, number?)
	if self.cameraMode ~= "STRIKE" then
		return nil, nil
	end
	local camera = workspace.CurrentCamera
	local ray = camera:ScreenPointToRay(position.X, position.Y)
	local center = self.ballPosition
	local oc = ray.Origin - center
	local b = oc:Dot(ray.Direction)
	local c = oc:Dot(oc) - BALL_RADIUS * BALL_RADIUS * 1.08
	local disc = b * b - c
	if disc < 0 then
		return nil, nil
	end
	local t = -b - math.sqrt(disc)
	local point = ray.Origin + ray.Direction * t
	local rel = camera.CFrame:VectorToObjectSpace(point - center) / BALL_RADIUS
	return math.clamp(rel.X, -1, 1), math.clamp(rel.Y, -1, 1)
end

function MomentVisuals:_tryStrike(position: Vector3)
	local hitX, hitY = self:_ballHit(position)
	if not hitX then
		return
	end
	self:_strike(hitX, hitY :: number)
end

function MomentVisuals:_strike(hitX: number, hitY: number)
	if self.phase ~= "STRIKE" then
		return
	end
	self.phase = "STRUCK"
	local info = self.strikeInfo
	local dir = self.strikeDir
	if self.onReticle then
		self.onReticle(nil)
	end
	-- Your foot comes through: back to the pitch view, you kick, the ball waits for the result.
	setHidden(self.me, false)
	for _, figure in self:_figures() do
		setHidden(figure, false)
	end
	self.me.facing = dir
	self.me:play("KICK")
	self:_grade(false)
	self:_clearAim()
	for _, ring in self.dangerRings do
		ring.part.Parent = nil
	end
	for _, b in self.bubbles do
		b.Enabled = false
	end
	if info.kind ~= "SHOT" then
		self:_blendCamera("PITCH", 0.5)
	end
	if self.onStrike then
		self.onStrike(dir.X, dir.Z, info.length, hitX, hitY, self.aimTime)
	end
end

---------------------------------------------------------------- results

-- The server turned the input down: back to the decision, clock still running.
function MomentVisuals:resume()
	if self.phase == "STRUCK" then
		self.phase = "DECIDE"
		self:_grade(true)
		self:_blendCamera("PITCH", 0.4)
		self.meRing.part.Parent = self.folder
		for i, ring in self.mateRings do
			ring.part.Parent = self.folder
		end
		for i, ring in self.dangerRings do
			local spec = self.layout.defenders[i]
			ring.part.Parent = if spec and spec.role == "PRESS" then self.folder else nil
		end
	end
end

-- Too slow: the presser takes the ball. Safe to call twice (local clock, then the server).
function MomentVisuals:tackle(tackler: number?)
	if self.tackled or not self.layout then
		return
	end
	self.tackled = true
	self.phase = "TACKLE"
	self.clock = 0
	self.dragging = nil
	self:_grade(false)
	self:_clearAim()
	if self.cameraMode ~= "PITCH" then
		self:_blendCamera("PITCH", 0.4)
	end
	setHidden(self.me, false)
	local index = tackler or self.layout.tackler
	local defender = self.defenders[index] or self.defenders[1]
	self.tackleBy = defender
	defender:play("LUNGE")
	self.me:play("STUMBLE")
	local carrier = flat(self.layout.carrier)
	local side = flat(defender.position - carrier)
	self.tackleBallTo = carrier + unit(side, Vector3.xAxis) * 4 + self.layout.toGoal:Cross(Vector3.yAxis) * 2
	for _, ring in self.dangerRings do
		ring.part.Parent = nil
	end
	for _, b in self.bubbles do
		b.Enabled = false
	end
end

-- Replays the server's pass (ground or lofted). onDecisive runs when it is clear who has it.
function MomentVisuals:playPass(result, onDecisive: () -> ())
	self.phase = "REPLAY"
	self.replay = { token = self.token, result = result, t = 0, onDecisive = onDecisive, decided = false, reacted = false }
	for _, ring in self.mateRings do
		ring.part.Parent = nil
	end
	self.meRing.part.Parent = nil
end

function MomentVisuals:_updateReplay(dt: number)
	local replay = self.replay
	local result = replay.result
	local step = result.sampleStep
	local headerHold = result.detail == "GOOD" and result.header
	if headerHold and replay.t >= result.eventTime - 0.3 then
		dt *= 0.25 -- the cross hangs at the header for a moment
	end
	replay.t += dt
	local t = replay.t
	self:_moveBall(trackAt(result.ball, step, t))
	local ball = self.ballPosition
	for i, defender in self.defenders do
		local track = result.defenders[i]
		if track then
			local at = trackAt(track, step, t)
			local ahead = trackAt(track, step, t + 0.05) - at
			defender:moveTo(at, if ahead.Magnitude > 0.05 then ahead else flat(ball - at), dt)
		end
	end
	for i, mate in self.mates do
		local track = result.mates[i]
		if track then
			mate:moveTo(trackAt(track, step, t), flat(ball - mate.position), dt)
		end
	end
	self.me:moveTo(self.me.position, flat(ball - self.me.position), dt)

	local lead = if headerHold or result.detail == "CLEARED" then 0.35 else 0.12
	if not replay.reacted and t >= result.eventTime - lead then
		replay.reacted = true
		local receiver = result.receiver and self.mates[result.receiver]
		local interceptor = result.interceptor and self.defenders[result.interceptor]
		if result.detail == "GOOD" and receiver then
			receiver:play(if result.header then "HEADER" else "TRAP")
		elseif interceptor then
			interceptor:play(if result.detail == "CLEARED" then "HEADER" else "LUNGE")
		elseif result.detail == "TOO_HARD" and receiver then
			receiver:play("LUNGE")
		end
	end
	if not replay.decided and t >= result.eventTime then
		replay.decided = true
		if result.interceptor then
			task.delay(0.6, function()
				if self.replay == replay then
					self.defenders[result.interceptor]:play("CHEER")
				end
			end)
		end
		replay.onDecisive()
	end
	self.lookAt = ball
end

-- A shot (yours, or a teammate's finish): ShotVisuals flies the ball and its camera takes over.
-- shooter: "ME" or a teammate index.
function MomentVisuals:handOffShot(shooter: any, spot: Vector3, header: boolean?)
	self.phase = "SHOT"
	self.replay = nil
	self:hideBall()
	local figure = if shooter == "ME" then self.me else self.mates[shooter]
	-- Our own camera from high behind the shooter (ShotVisuals' low shot camera would sit behind
	-- everyone's backs out here).
	self.shotSpot = flat(spot)
	self.shotShooter = figure
	self.shotClock = 0
	self:_blendCamera("SHOT", 0.45)
	if figure and shooter ~= "ME" then
		local toGoal = unit(flat(-spot), Vector3.new(0, 0, -1))
		figure:place(if header then flat(spot) - toGoal * 0.4 else standFor(spot, toGoal), toGoal)
		figure:play(if header then "HEADER" else "KICK")
	end
	for _, ring in self.mateRings do
		ring.part.Parent = nil
	end
	self.meRing.part.Parent = nil
end

-- A blocked shot: the defender who got in the way throws himself at it.
function MomentVisuals:block(defender: number?)
	local d = defender and self.defenders[defender]
	if d then
		d:play("LUNGE")
	end
end

-- The scorer celebrates (random), the others cheer; the camera comes in close.
function MomentVisuals:celebrate(who: any)
	local scorer = if who == "ME" then self.me else self.mates[who]
	if not scorer then
		return
	end
	local token = self.token
	local side = if scorer.position.X >= 0 then 1 else -1
	scorer.facing = unit(Vector3.new(side, 0, 0.6), Vector3.new(0, 0, 1))
	scorer:celebrate()
	for _, figure in { self.me, self.mates[1], self.mates[2] } do
		if figure ~= scorer then
			figure:play("CHEER")
		end
	end
	self.focus = scorer
	task.delay(0.35, function()
		if self.token == token then
			self:_blendCamera("FOCUS", 0.7)
		end
	end)
end

---------------------------------------------------------------- per frame

local function decideCamera(layout): (Vector3, Vector3)
	-- High behind you looking up the pitch (the reference's view): pitched down CAMERA_PITCH and
	-- placed so the goal line sits ~1/3 down the screen (clear of the scoreboard) and your feet
	-- ~4/5 down (clear of the hint). Derived from the vertical field of view.
	local c = layout.carrier
	local half = math.rad(DECIDE_FOV / 2)
	local pitch = math.rad(CAMERA_PITCH)
	local goalAngle = pitch + math.atan(-0.36 * math.tan(half)) -- screen y 0.32
	local carrierAngle = pitch + math.atan(0.6 * math.tan(half)) -- screen y 0.80
	local tg, tc = math.tan(goalAngle), math.tan(carrierAngle)
	local back = tc * c.Z / (tc - tg) -- camera Z
	local height = tg * back
	local position = Vector3.new(c.X * 0.4, height, back)
	local look = position + Vector3.new(0, -math.sin(pitch), -math.cos(pitch)) * 10
	return position, look
end

function MomentVisuals:_updateCamera(dt: number)
	local mode = self.cameraMode
	if mode == "NONE" then
		return
	end
	local camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	local target, fov
	if mode == "STUDIO" then
		self.studioClock = (self.studioClock or 0) + dt
		local swing = math.sin(self.studioClock * 0.08)
		local position = Vector3.new(swing * 30, 34, 96)
		target, fov = CFrame.lookAt(position, Vector3.new(swing * 10, 4, 8)), 50
	elseif mode == "STRIKE" then
		target, fov = self.strikeCamera, STRIKE_FOV
	elseif mode == "FOCUS" and self.focus then
		local f = self.focus.model:GetPivot().Position
		local from = Vector3.new(f.X * 0.85, 8.5, f.Z + 15)
		target, fov = CFrame.lookAt(from, f + Vector3.new(0, 1.2, 0)), 40
	elseif mode == "SHOT" and self.shotSpot then
		local spot = self.shotSpot
		self.shotClock += dt
		-- A slow push in while the ball flies.
		local back = SHOT_BACK - 3 * smooth(math.min(self.shotClock / 1.6, 1))
		local position = spot + unit(spot, Vector3.new(0, 0, 1)) * back + Vector3.new(0, SHOT_HEIGHT, 0)
		target, fov = CFrame.lookAt(position, GOAL_MOUTH:Lerp(spot, 0.3)), SHOT_FOV
	elseif self.layout then
		local position, look = decideCamera(self.layout)
		if self.lookAt then
			-- Follow the ball a little during a pass.
			local shift = flat(self.lookAt - look) * 0.45
			position += shift
			look += shift
		end
		self.smoothPosition = if self.smoothPosition then self.smoothPosition:Lerp(position, math.min(1, dt * 3)) else position
		self.smoothLook = if self.smoothLook then self.smoothLook:Lerp(look, math.min(1, dt * 3)) else look
		target, fov = CFrame.lookAt(self.smoothPosition, self.smoothLook), DECIDE_FOV
	else
		return
	end
	if self.blendT < 1 then
		self.blendT = math.min(1, self.blendT + dt / self.blendTime)
		local k = smooth(self.blendT)
		camera.CFrame = self.blendFrom:Lerp(target, k)
		camera.FieldOfView = self.blendFov + (fov - self.blendFov) * k
	else
		camera.CFrame = target
		camera.FieldOfView = fov
	end
end

-- Whoever stands between the camera and what matters (the goal on a shot, the scorer when he
-- celebrates) or right in front of the lens fades to see-through; everyone else back to solid.
function MomentVisuals:_updateFade(dt: number)
	local mode = self.cameraMode
	local focus, keep
	if mode == "SHOT" and self.shotSpot then
		focus, keep = GOAL_MOUTH, self.shotShooter
	elseif mode == "FOCUS" and self.focus then
		focus, keep = self.focus.model:GetPivot().Position + Vector3.new(0, 1.5, 0), self.focus
	end
	local eye = workspace.CurrentCamera.CFrame.Position
	local k = math.min(1, dt * 8)
	for _, figure in self:_figures() do
		local want = 0
		if focus and figure ~= keep then
			local chest = figure.model:GetPivot().Position + Vector3.new(0, 1.5, 0)
			local d, t = segmentDistance(chest, eye, focus)
			if (d < FADE_RADIUS and t > 0.02 and t < 0.97) or (chest - eye).Magnitude < FADE_NEAR then
				want = FADE
			end
		end
		local now = figure.fade or 0
		setFade(figure, if math.abs(want - now) < 0.02 then want else now + (want - now) * k)
	end
end

function MomentVisuals:update(dt: number)
	self:_updateCamera(dt)
	self:_updateFade(dt)
	if not self.active or not self.layout then
		return
	end
	local layout = self.layout
	local carrier = layout.carrier
	local toGoal = layout.toGoal
	local slow = {}

	if self.phase == "INTRO" then
		self.clock += dt
		local t = self.clock
		local intro = self.intro
		local stand = standFor(carrier, toGoal)
		if layout.passer then
			-- A pass to you: kicked at 0.3 s, at your feet just before the end.
			local passer = self.mates[layout.passer]
			local kickAt, arriveAt = 0.3, intro - 0.45
			if t >= kickAt and not self.introKicked then
				self.introKicked = true
				passer:play("KICK")
			end
			if t < kickAt + 0.08 then
				self:_setBall(flat(self.introBallFrom) + Vector3.new(0, BALL_RADIUS, 0))
			else
				local k = math.clamp((t - kickAt - 0.08) / (arriveAt - kickAt - 0.08), 0, 1)
				self:_moveBall(flat(self.introBallFrom):Lerp(flat(carrier), 1 - (1 - k) * (1 - k)) + Vector3.new(0, BALL_RADIUS, 0))
			end
			if t >= arriveAt - 0.12 and not self.introTrapped then
				self.introTrapped = true
				self.me:play("TRAP")
			end
			if layout.kind == "ONE_TWO" then
				-- You sprint on to meet it.
				local k = smooth(t / arriveAt)
				self.me:moveTo(self.introFrom.me:Lerp(stand, k), toGoal, dt)
			else
				self.me:moveTo(stand, if t < arriveAt then flat(self.ballPosition - stand) else toGoal, dt)
			end
			passer:moveTo(passer.position, flat(self.ballPosition - passer.position), dt)
		else
			-- A few touches forward with the ball.
			local k = smooth(t / (intro - 0.1))
			local ballAt = flat(self.introBallFrom):Lerp(flat(carrier), k)
			self:_moveBall(ballAt + toGoal * math.abs(math.sin(t * 9)) * 0.5 + Vector3.new(0, BALL_RADIUS, 0))
			self.me:moveTo(standFor(ballAt, toGoal), toGoal, dt)
		end
		for i, defender in self.defenders do
			local spec = layout.defenders[i]
			if spec then
				local from = self.introFrom[defender] or spec.from
				defender:moveTo(from:Lerp(spec.from, smooth(t / intro)), flat(self.ballPosition - defender.position), dt)
			end
		end
		for i, mate in self.mates do
			if i ~= layout.passer then
				local from = self.introFrom[mate] or mate.position
				local spec = layout.teammates[i]
				mate:moveTo(from:Lerp(spec.from, smooth(t / intro)), flat(self.ballPosition - mate.position), dt)
			end
		end
		if t >= intro then
			self.introKicked, self.introTrapped = false, false
			self.phase = "DECIDE"
			self.decision = 0
			self:_setBall(carrier + Vector3.new(0, BALL_RADIUS, 0))
			self:_grade(true)
			for i, ring in self.dangerRings do
				local spec = layout.defenders[i]
				ring.part.Parent = if spec and spec.role == "PRESS" then self.folder else nil
			end
			if self.onReady then
				self.onReady(layout.step)
			end
		end
	elseif self.phase == "DECIDE" or self.phase == "STRIKE" then
		if self.phase == "DECIDE" then
			self.decision += dt
		else
			-- The strike screen has its own clock; the world holds still.
			self.strikeClock += dt
			local left = 1 - self.strikeClock / Config.StrikeTime
			if self.onStrikeTimer then
				self.onStrikeTimer(left)
			end
			if left <= 0 then
				-- Rushed: a scuffed hit somewhere on the ball.
				local angle = math.random() * math.pi * 2
				self:_strike(math.cos(angle) * 0.85, math.sin(angle) * 0.85)
			end
		end
		local t = self.decision
		for i, defender in self.defenders do
			if layout.defenders[i] then
				local at = MomentPhysics.defenderAt(layout, i, t)
				defender:moveTo(at, flat(carrier - at), dt * SLOW)
				slow[defender] = true
				placeRing(self.dangerRings[i], at)
			end
		end
		for i, mate in self.mates do
			local at = MomentPhysics.mateAt(layout, i, t)
			local spec = layout.teammates[i]
			local running = spec.speed > 0 and flat(at - spec.to).Magnitude > 0.2
			mate:moveTo(at, if running then flat(spec.to - spec.from) else flat(carrier - at), dt * SLOW)
			slow[mate] = true
			placeRing(self.mateRings[i], at)
			local open = MomentPhysics.isOpen(layout, i, t)
			self.bubbles[i].Enabled = self.phase == "DECIDE" and open
			self.bubbles[i].StudsOffset = Vector3.new(0, 2.6 + 0.25 * math.sin(os.clock() * 5 + i), 0)
			local targeted = self.aimInfo and self.aimInfo.mate == i
			self.mateRings[i].stroke.Color = if targeted then GOLD elseif open then LIME else LILAC
		end
		local facing = if self.aimInfo and self.aimInfo.kind ~= "SHORT" then unit(flat(self.aimInfo.target - carrier), toGoal) else toGoal
		self.me:moveTo(standFor(carrier, facing), facing, dt * SLOW)
		slow[self.me] = true
		placeRing(self.meRing, carrier)
		if self.phase == "DECIDE" and t >= layout.tackleTime then
			self:tackle(nil)
		end
	elseif self.phase == "STRUCK" then
		-- Waiting for the server: the kick plays, the ball barely moves.
		for i, defender in self.defenders do
			if layout.defenders[i] then
				defender:moveTo(defender.position, flat(carrier - defender.position), dt)
			end
		end
	elseif self.phase == "TACKLE" then
		self.clock += dt
		self:_moveBall(flat(carrier):Lerp(self.tackleBallTo, smooth(self.clock / 0.5)) + Vector3.new(0, BALL_RADIUS, 0))
		local tackler = self.tackleBy
		if tackler and self.clock < 0.4 then
			tackler:moveTo(tackler.position:Lerp(flat(carrier), math.min(1, dt * 6)), flat(carrier - tackler.position), dt)
		end
	elseif self.phase == "REPLAY" and self.replay and self.replay.token == self.token then
		self:_updateReplay(dt)
	end

	if self.onTimer then
		self.onTimer(self:timeLeft())
	end
	for _, figure in self:_figures() do
		figure:update(if slow[figure] then dt * SLOW else dt)
	end
end

return MomentVisuals
