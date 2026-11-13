-- Client-only 3D visuals: camera, ball replay, goalkeeper animation, aim crosshair, trajectory
-- preview and effects. Everything here is local to this player and has no effect on the outcome.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShotConfig = require(Shared:WaitForChild("ShotConfig"))
local ShotPhysics = require(Shared:WaitForChild("ShotPhysics"))
local KeeperAnimator = require(script.Parent:WaitForChild("KeeperAnimator"))

local Keeper = ShotConfig.Goalkeeper
local BALL_RADIUS = ShotConfig.Ball.Radius
local PREVIEW_DOTS = 16
local AFTER_PATH_SECONDS = 0.4 -- linger after the replayed path ends

local WHITE = Color3.new(1, 1, 1)
local GOLD = Color3.fromRGB(255, 191, 31)
local RED = Color3.fromRGB(255, 45, 85)
local VIOLET = Color3.fromRGB(123, 77, 255)
local CREAM = Color3.fromRGB(247, 236, 214)

local ShotVisuals = {}
ShotVisuals.__index = ShotVisuals

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
	props.Material = props.Material or Enum.Material.SmoothPlastic
	return create("Part", props)
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

-- Position on the replayed path at time t (linear between samples).
local function pathAt(path: { Vector3 }, sampleStep: number, t: number): Vector3
	local f = t / sampleStep
	local i = math.floor(f)
	if i >= #path - 1 then
		return path[#path]
	end
	return path[i + 1]:Lerp(path[i + 2], f - i)
end

function ShotVisuals.new()
	local self = setmetatable({}, ShotVisuals)
	self.token = 0
	self.clock = 0
	self.shake = 0
	self.fovKick = 0
	self.ballRotation = CFrame.identity
	self.active = true
	self.blendT = 1
	self.spot = ShotPhysics.ballSpot()

	local folder = create("Folder", { Name = "ShotVisuals", Parent = workspace })

	-- Ball: white sphere with 12 flat dark panels, plus a trail for hard shots.
	local ballModel = create("Model", { Name = "Ball", Parent = folder })
	local shell = makePart({ Name = "Shell", Shape = Enum.PartType.Ball, Size = Vector3.one * BALL_RADIUS * 2, Color = WHITE, Parent = ballModel })
	self.ballParts = { { shell, CFrame.identity } }
	for _, dir in icosahedronDirections() do
		local reference = if math.abs(dir.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis
		local patch = makePart({
			Name = "Panel",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.05, BALL_RADIUS * 0.66, BALL_RADIUS * 0.66),
			Color = Color3.fromRGB(28, 18, 48),
			CastShadow = false,
			Parent = ballModel,
		})
		table.insert(self.ballParts, { patch, CFrame.fromMatrix(dir * BALL_RADIUS * 0.985, dir, dir:Cross(reference).Unit) })
	end
	-- The trail hangs off a separate carrier so the ball's spin doesn't twist it.
	local carrier = makePart({ Name = "TrailCarrier", Size = Vector3.one * 0.2, Transparency = 1, Parent = folder })
	local a0 = create("Attachment", { Position = Vector3.new(0, 0.55, 0), Parent = carrier })
	local a1 = create("Attachment", { Position = Vector3.new(0, -0.55, 0), Parent = carrier })
	self.trail = create("Trail", {
		Attachment0 = a0,
		Attachment1 = a1,
		Lifetime = 0.22,
		MinLength = 0.05,
		FaceCamera = true,
		LightEmission = 0.7,
		Color = ColorSequence.new(CREAM, GOLD),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) }),
		WidthScale = NumberSequence.new(1, 0.2),
		Enabled = false,
		Parent = carrier,
	})
	self.trailCarrier = carrier

	-- Crosshair on the goal plane, the size of the ball, drawn on top of everything.
	local aimPart = makePart({ Name = "Crosshair", Size = Vector3.new(3, 3, 0.05), Transparency = 1, CastShadow = false, Parent = folder })
	local aimGui = create("SurfaceGui", {
		Face = Enum.NormalId.Back,
		AlwaysOnTop = true,
		LightInfluence = 0,
		SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
		PixelsPerStud = 60,
		Enabled = false,
		Parent = aimPart,
	})
	local ring = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(2 * BALL_RADIUS / 3, 2 * BALL_RADIUS / 3),
		BackgroundColor3 = GOLD,
		BackgroundTransparency = 0.82,
		Parent = aimGui,
	})
	create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = ring })
	create("UIStroke", { Color = GOLD, Thickness = 6, Parent = ring })
	create("UIStroke", { Color = Color3.fromRGB(43, 18, 80), Thickness = 2, Transparency = 0.2, Parent = create("Frame", {
		Size = UDim2.new(1, 14, 1, 14), Position = UDim2.fromOffset(-7, -7), BackgroundTransparency = 1, Parent = ring,
	}) })
	local dot = create("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(14, 14), BackgroundColor3 = CREAM, Parent = aimGui })
	create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = dot })
	for _, tick in { { 0.5, 0.06, 6, 22 }, { 0.5, 0.94, 6, 22 }, { 0.06, 0.5, 22, 6 }, { 0.94, 0.5, 22, 6 } } do
		create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(tick[1], tick[2]),
			Size = UDim2.fromOffset(tick[3], tick[4]),
			BackgroundColor3 = GOLD,
			BorderSizePixel = 0,
			Parent = aimGui,
		})
	end
	self.aimPart, self.aimGui = aimPart, aimGui

	self.dots = {}
	for i = 1, PREVIEW_DOTS do
		self.dots[i] = makePart({
			Name = "PreviewDot",
			Shape = Enum.PartType.Ball,
			Size = Vector3.one * (0.42 - 0.22 * i / PREVIEW_DOTS),
			Color = GOLD,
			Material = Enum.Material.Neon,
			CastShadow = false,
			Transparency = 1,
			Parent = folder,
		})
	end
	self.previewKey = ""

	local function emitter(name: string, position: Vector3, props: { [string]: any })
		local holder = makePart({ Name = name, Size = Vector3.one, Transparency = 1, CFrame = CFrame.new(position), Parent = folder })
		props.Enabled = false
		props.Parent = holder
		return create("ParticleEmitter", props), holder
	end
	self.confetti = emitter("Confetti", Vector3.new(0, ShotConfig.Goal.Height + 1, -ShotConfig.Goal.NetDepth / 2), {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, GOLD),
			ColorSequenceKeypoint.new(0.35, RED),
			ColorSequenceKeypoint.new(0.7, VIOLET),
			ColorSequenceKeypoint.new(1, CREAM),
		}),
		Size = NumberSequence.new(0.55, 0.15),
		Speed = NumberRange.new(28, 50),
		SpreadAngle = Vector2.new(75, 75),
		EmissionDirection = Enum.NormalId.Top,
		Acceleration = Vector3.new(0, -40, 0),
		Drag = 1.5,
		Lifetime = NumberRange.new(1.6, 2.6),
		RotSpeed = NumberRange.new(-220, 220),
		LightEmission = 0.6,
	})
	-- Small burst of chalk/grass at bounces and white flashes on the frame.
	self.impact, self.impactHolder = emitter("Impact", Vector3.zero, {
		Color = ColorSequence.new(CREAM),
		Size = NumberSequence.new(0.5, 0),
		Speed = NumberRange.new(6, 14),
		SpreadAngle = Vector2.new(180, 180),
		Acceleration = Vector3.new(0, -30, 0),
		Lifetime = NumberRange.new(0.25, 0.45),
		LightEmission = 0.8,
	})

	self:_findScene()
	self:reset()
	return self
end

function ShotVisuals:_findScene()
	local scene = workspace:WaitForChild("FootballScene", 15)
	if not scene then
		warn("[ShotVisuals] workspace.FootballScene not found; is the server Main script running?")
		return
	end
	local net = scene:FindFirstChild("NetBack", true)
	if net and net:IsA("BasePart") then
		self.netBack, self.netBackHome = net, net.CFrame
	end
	local keeper = Keeper.Enabled and scene:WaitForChild("Goalkeeper", 10)
	if keeper then
		self.keeper = KeeperAnimator.new(keeper)
	end
end

function ShotVisuals:_setBall(position: Vector3)
	local base = CFrame.new(position) * self.ballRotation
	for _, entry in self.ballParts do
		entry[1].CFrame = base * entry[2]
	end
	self.trailCarrier.CFrame = CFrame.new(position)
	self.ballPosition = position
end

function ShotVisuals:_spinBall(angularVelocity: Vector3, dt: number)
	local speed = angularVelocity.Magnitude
	if speed > 1e-3 then
		self.ballRotation = CFrame.fromAxisAngle(angularVelocity / speed, speed * dt) * self.ballRotation
	end
end

-- spot: where the ball is (default: the shot drill's spot; a shot after a pass starts at the receiver).
function ShotVisuals:reset(spot: Vector3?)
	self.token += 1
	self.holdBall = false
	self.ballRotation = CFrame.identity
	self.trail.Enabled = false
	local newSpot = spot or ShotPhysics.ballSpot()
	if self.active and self.spot and (newSpot - self.spot).Magnitude > 0.1 then
		-- New shooting position: glide the camera over instead of cutting.
		local camera = workspace.CurrentCamera
		self.blendFrom, self.blendFov, self.blendT = camera.CFrame, camera.FieldOfView, 0
	end
	self.spot = newSpot
	self:_setBall(self.spot)
	if self.keeper then
		self.keeper:recover()
	end
	if self.netBack then
		self.netBack.CFrame = self.netBackHome
	end
	self:updateAiming(false, 0, 0.5, 0, false)
end

-- The shot camera sits behind the ball on the line to the goal, as far back and as high as for the
-- shot drill's own spot (where this gives exactly ShotConfig.Camera.Position).
function ShotVisuals.cameraPosition(spot: Vector3): Vector3
	local cam = ShotConfig.Camera.Position
	local home = ShotPhysics.ballSpot()
	local back = Vector3.new(cam.X - home.X, 0, cam.Z - home.Z).Magnitude
	local away = Vector3.new(spot.X, 0, spot.Z)
	away = if away.Magnitude > 1e-3 then away.Unit else Vector3.new(0, 0, 1)
	return Vector3.new(spot.X, cam.Y, spot.Z) + away * back
end

-- Off while another drill (the pass) owns the camera: the ball is put away, the keeper idles.
function ShotVisuals:setActive(active: boolean)
	if self.active == active then
		return
	end
	self.active = active
	if active then
		local camera = workspace.CurrentCamera
		self.blendFrom, self.blendFov, self.blendT = camera.CFrame, camera.FieldOfView, 0
		self:reset()
	else
		self.token += 1 -- stops any replay in progress
		self.holdBall = false
		if self.keeper then
			self.keeper:recover() -- back on his feet after the last shot
		end
		self.trail.Enabled = false
		self:_setBall(Vector3.new(0, -50, 0))
		self:updateAiming(false, 0, 0.5, 0, false)
	end
end

function ShotVisuals:setCharging(on: boolean)
	if self.keeper then
		self.keeper:setCharging(on)
	end
end

-- Settings: camera shake on goals and frame hits.
function ShotVisuals:setShakeEnabled(enabled: boolean)
	self.shakeEnabled = enabled
end

-- Per-frame: camera (with shake and kick) and the keeper.
function ShotVisuals:update(dt: number)
	self.clock += dt
	self.shake = math.max(0, self.shake - dt * 2.5)
	self.fovKick = math.max(0, self.fovKick - dt * 10)

	if self.active then
		local camera = workspace.CurrentCamera
		camera.CameraType = Enum.CameraType.Scriptable
		local fov = ShotConfig.Camera.FieldOfView - self.fovKick
		local base = CFrame.lookAt(ShotVisuals.cameraPosition(self.spot), ShotConfig.Camera.LookAt)
		if self.shake > 0 and self.shakeEnabled ~= false then
			local t = self.clock * 25
			local amount = self.shake * 0.3
			base *= CFrame.new(math.noise(t, 1) * amount, math.noise(t, 2) * amount, 0)
		end
		if self.blendT < 1 then
			-- Coming back from the pass drill: glide to the shot camera.
			self.blendT = math.min(1, self.blendT + dt / 0.9)
			local k = self.blendT * self.blendT * (3 - 2 * self.blendT)
			base = self.blendFrom:Lerp(base, k)
			fov = self.blendFov + (fov - self.blendFov) * k
		end
		camera.FieldOfView = fov
		camera.CFrame = base
	end

	if self.keeper then
		self.keeper:update(dt)
		if self.holdBall then
			local hands = self.keeper:handsPosition()
			if hands then
				self:_setBall(self.ballPosition:Lerp(hands, math.min(1, dt * 25)))
			end
		end
	end
end

-- Shows the crosshair, and while holding, the predicted arc including curl (no random error).
function ShotVisuals:updateAiming(enabled: boolean, aimX: number, aimY: number, power: number, holding: boolean)
	local point = ShotPhysics.aimToGoalPoint(aimX, aimY)
	self.aimGui.Enabled = enabled
	self.aimPart.CFrame = CFrame.new(point + Vector3.new(0, 0, 0.25))

	local showArc = enabled and holding
	for i, dot in self.dots do
		dot.Transparency = if showArc then 0.1 + 0.55 * i / PREVIEW_DOTS else 1
	end
	if not showArc then
		self.previewKey = ""
		return
	end
	-- Re-solve only when the input actually changed.
	local key = string.format("%.3f|%.3f|%.2f", aimX, aimY, power)
	if key == self.previewKey then
		return
	end
	self.previewKey = key
	local points = ShotPhysics.previewPath(point, power, ShotPhysics.spinFor(aimX, power), PREVIEW_DOTS, self.spot)
	for i, dot in self.dots do
		local p = points[i]
		if p then
			dot.CFrame = CFrame.new(p)
		else
			dot.Transparency = 1
		end
	end
end

function ShotVisuals:onShotReleased()
	self.fovKick = 1.8
	self:updateAiming(false, 0, 0.5, 0, false)
	if self.keeper then
		self.keeper:setCharging(false)
	end
end

function ShotVisuals:_bulgeNet(at: Vector3)
	local net = self.netBack
	if not net then
		return
	end
	local depth = math.clamp(1.2 - math.abs(at.X) / ShotConfig.Goal.Width, 0.5, 1.2)
	net.CFrame = self.netBackHome * CFrame.new(0, 0, -depth)
	TweenService:Create(net, TweenInfo.new(0.7, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out), { CFrame = self.netBackHome }):Play()
end

function ShotVisuals:_puff(at: Vector3, count: number)
	self.impactHolder.CFrame = CFrame.new(at)
	self.impact:Emit(count)
end

-- Replays the server-simulated shot. Calls onDecisive at the moment the result is clear,
-- and yields until the replay ends or reset() is called.
function ShotVisuals:playShot(result, onDecisive: () -> ())
	self.token += 1
	local token = self.token
	local path: { Vector3 } = result.path
	local sampleStep: number = result.sampleStep
	local duration = (#path - 1) * sampleStep
	local spin: Vector3 = result.spin or Vector3.zero

	if self.keeper then
		self.keeper:startShot({
			reaction = result.keeperReaction,
			impactTime = result.keeperTime or result.decisiveTime,
			target = result.keeperTarget,
			kind = result.keeperKind,
			dives = result.keeperDives,
		})
	end

	-- Effects keyed to simulation events.
	local pending = table.clone(result.events)
	table.sort(pending, function(a, b)
		return a.t < b.t
	end)
	local decisiveFired = false
	self.trail.Enabled = (result.speedKmh or 0) >= 85

	local t, last = 0, self.spot
	while t < duration + AFTER_PATH_SECONDS do
		local dt = RunService.RenderStepped:Wait()
		if self.token ~= token then
			return
		end
		t += dt

		while pending[1] and pending[1].t <= t do
			local e = table.remove(pending, 1)
			if e.kind == "goal" then
				self.shake = 1
				self.confetti:Emit(160)
			elseif e.kind == "net" then
				self:_bulgeNet(e.pos)
			elseif e.kind == "frame" then
				self.shake = math.max(self.shake, 0.6)
				self:_puff(e.pos, 14)
			elseif e.kind == "keeper" then
				self.shake = math.max(self.shake, 0.35)
				if e.part == "CATCH" then
					self.holdBall = true -- update() keeps it in the gloves from now on
					self.trail.Enabled = false
				else
					self:_puff(e.pos, 10)
				end
			elseif e.kind == "bounce" or e.kind == "board" then
				self:_puff(e.pos, 6)
			end
		end
		if not decisiveFired and t >= result.decisiveTime then
			decisiveFired = true
			onDecisive()
		end

		if not self.holdBall then
			local position = pathAt(path, sampleStep, math.min(t, duration))
			local velocity = (position - last) / math.max(dt, 1e-3)
			local onGround = position.Y <= BALL_RADIUS + 0.05
			-- In the air the ball shows its real spin (exaggerated); on the ground it rolls.
			local angular = if onGround then Vector3.new(velocity.Z, 0, -velocity.X) / BALL_RADIUS else spin * 3 + Vector3.new(-velocity.Magnitude * 0.15, 0, 0)
			self:_spinBall(angular, dt)
			if velocity.Magnitude < 40 then
				self.trail.Enabled = false
			end
			self:_setBall(position)
			last = position
		end
	end
	if not decisiveFired then
		onDecisive()
	end
	self.trail.Enabled = false
end

return ShotVisuals
