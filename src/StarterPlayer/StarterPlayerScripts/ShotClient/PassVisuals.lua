-- 3D side of the pass drill: camera, the four players, ball, ground markers, the aiming line,
-- and the replay of the server's simulated pass. Everything is local to this client.
-- After a good pass the receiver shoots (beginFollowUp): the shot drill (ShotVisuals) owns the
-- camera and the ball then, and this keeps the players on the pitch, lines the receiver up
-- behind the ball and fades anyone standing between the camera and the goal while aiming.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShotConfig = require(Shared:WaitForChild("ShotConfig"))
local PassConfig = require(Shared:WaitForChild("PassConfig"))
local PassPhysics = require(Shared:WaitForChild("PassPhysics"))
local FigureBuilder = require(Shared:WaitForChild("FigureBuilder"))
local FigureAnimator = require(script.Parent:WaitForChild("FigureAnimator"))

local BALL_RADIUS = ShotConfig.Ball.Radius
local SCALE = ShotConfig.Goalkeeper.ModelScale
local LINE_DOTS = 22
local CAMERA_BLEND = 0.9
local FADE = 0.65 -- LocalTransparencyModifier for players blocking the view of the goal
local FADE_WIDTH = 4.5 -- studs either side of the camera-to-goal line

local rgb = Color3.fromRGB
local WHITE = Color3.new(1, 1, 1)
local GOLD = rgb(255, 191, 31)
local LILAC = rgb(190, 168, 255)
local RED = rgb(255, 45, 85)

local SKIN = rgb(214, 132, 82)
local HAIR = rgb(52, 32, 26)
-- Kits are painted on from the character sheets (tools/assets/build_players.py): our team in
-- navy, the rival in black and red. These colours only show if images are unavailable.
local NAVY = rgb(26, 36, 110)
local TEAM_KIT = { skin = SKIN, shirt = NAVY, shorts = NAVY, socks = NAVY, boots = rgb(236, 232, 244), hair = HAIR }
local BLACK = rgb(24, 18, 26)
local OPPONENT_KIT = { skin = SKIN, shirt = BLACK, shorts = BLACK, socks = BLACK, boots = rgb(236, 232, 244), hair = HAIR }

local PassVisuals = {}
PassVisuals.__index = PassVisuals

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

-- Flat circle on the grass, drawn as a crisp GUI on the part's top face.
local function groundCircle(parent: Instance, name: string, radius: number, color: Color3, fill: number)
	local part = makePart({ Name = name, Size = Vector3.new(radius * 2, 0.05, radius * 2), Transparency = 1, Parent = parent })
	local gui = create("SurfaceGui", {
		Face = Enum.NormalId.Top,
		LightInfluence = 0,
		SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
		PixelsPerStud = 24,
		Parent = part,
	})
	local circle = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -8, 1, -8),
		BackgroundColor3 = color,
		BackgroundTransparency = fill,
		Parent = gui,
	})
	create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = circle })
	local stroke = create("UIStroke", { Color = color, Thickness = 4, Parent = circle })
	return { part = part, frame = circle, stroke = stroke, gui = gui }
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

-- Position on a sampled track at time t (linear between samples).
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

function PassVisuals.new()
	local self = setmetatable({}, PassVisuals)
	self.clock = 0
	self.frozen = false
	self.token = 0
	self.ballRotation = CFrame.identity
	self.active = false

	local folder = create("Folder", { Name = "PassVisuals" })
	self.folder = folder

	-- Ball, same look as the shot drill's.
	local ballModel = create("Model", { Name = "Ball", Parent = folder })
	local shell = makePart({ Name = "Shell", Shape = Enum.PartType.Ball, Size = Vector3.one * BALL_RADIUS * 2, Color = WHITE, CastShadow = true, Parent = ballModel })
	self.ballParts = { { shell, CFrame.identity } }
	for _, dir in icosahedronDirections() do
		local reference = if math.abs(dir.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis
		local patch = makePart({
			Name = "Panel",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.05, BALL_RADIUS * 0.66, BALL_RADIUS * 0.66),
			Color = rgb(28, 18, 48),
			Parent = ballModel,
		})
		table.insert(self.ballParts, { patch, CFrame.fromMatrix(dir * BALL_RADIUS * 0.985, dir, dir:Cross(reference).Unit) })
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
		animator.fadeParts = {}
		animator.fade = 0
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") or d:IsA("Decal") or d:IsA("SurfaceGui") then
				table.insert(animator.fadeParts, d)
			end
		end
		return animator
	end
	-- You pass (your number printed on the shirt); #7 and #28 receive; the rival #9 defends.
	self.passer = figure("Passer", TEAM_KIT, "PlayerMain", 10)
	self.mates = { figure("Teammate1", TEAM_KIT, "Teammate7"), figure("Teammate2", TEAM_KIT, "Teammate28") }
	self.defender = figure("Defender", OPPONENT_KIT, "Rival9")

	-- Ground markers: where teammates can take the ball, and the defender's reach.
	self.mateRings = {
		groundCircle(folder, "MateRing1", PassConfig.Teammate.Reach + 0.8, LILAC, 0.85),
		groundCircle(folder, "MateRing2", PassConfig.Teammate.Reach + 0.8, LILAC, 0.85),
	}
	self.defenderZone = groundCircle(folder, "DefenderZone", PassConfig.Defender.Reach, RED, 0.7)
	self.targetRing = groundCircle(folder, "Target", 1.6, GOLD, 0.6)
	self.dots = {}
	for i = 1, LINE_DOTS do
		self.dots[i] = makePart({
			Name = "LineDot",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.06, 0.55, 0.55),
			Color = GOLD,
			Material = Enum.Material.Neon,
			Transparency = 1,
			Parent = folder,
		})
	end
	return self
end

-- The passer is you: your career's number and surname on his shirt.
function PassVisuals:setPasser(number: number, surname: string)
	FigureBuilder.setPrints(self.passer.model, number, surname)
end

-- Shows the drill (parents everything into the workspace) and moves the camera over.
function PassVisuals:enter()
	if self.active and not self.followUp then
		return
	end
	self:_endFollowUp()
	self.active = true
	self.folder.Parent = workspace
	local camera = workspace.CurrentCamera
	self.blendFrom, self.blendFov, self.blendT = camera.CFrame, camera.FieldOfView, 0
end

function PassVisuals:exit()
	self:_endFollowUp()
	self.active = false
	self.folder.Parent = nil
end

local function setFade(animator, amount: number)
	if animator.fade == amount then
		return
	end
	animator.fade = amount
	for _, part in animator.fadeParts do
		if part:IsA("SurfaceGui") then
			part.Enabled = amount < 0.5 -- faces and prints can't fade, so they hide with the body
		else
			part.LocalTransparencyModifier = amount
		end
	end
end

function PassVisuals:_figures()
	return { self.passer, self.mates[1], self.mates[2], self.defender }
end

function PassVisuals:_endFollowUp()
	self.followUp = nil
	for _, figure in self:_figures() do
		setFade(figure, 0)
	end
end

-- The shot after a good pass: receiver index, ball spot and the shot camera's position.
function PassVisuals:beginFollowUp(receiver: number, spot: Vector3, cameraPosition: Vector3)
	if not (self.active and self.layout and self.mates[receiver]) then
		return -- nothing on the pitch to line up (e.g. joined mid-way); the shot still works
	end
	self.replay = nil
	self.frozen = true
	self.highlight = nil
	local toGoal = flat(-spot)
	toGoal = if toGoal.Magnitude > 1e-3 then toGoal.Unit else Vector3.new(0, 0, -1)
	local right = toGoal:Cross(Vector3.yAxis)
	self.followUp = {
		receiver = receiver,
		spot = spot,
		camera = flat(cameraPosition),
		stand = flat(spot - toGoal * 1.3 - right * 0.8), -- ball on his right foot
		toGoal = toGoal,
		kicked = false,
	}
	self:_setBall(Vector3.new(0, -50, 0)) -- the shot drill's ball takes over
	for _, ring in self.mateRings do
		ring.part.Parent = nil
	end
	self.defenderZone.part.Parent = nil
	self:updateAiming(false, nil, 0, false)
	self.mates[receiver]:play(nil)
end

-- The player released the shot: the receiver strikes it, everyone visible again.
function PassVisuals:followUpKick()
	local fu = self.followUp
	if fu then
		fu.kicked = true
		self.mates[fu.receiver]:play("KICK")
	end
end

-- The shot after the pass went in: the scorer sprints towards the near corner flag and goes into
-- a knee slide (see _updateFollowUp).
function PassVisuals:celebrateGoal()
	local fu = self.followUp
	if fu and not fu.celebration then
		local side = if fu.spot.X >= 0 then 1 else -1
		fu.celebration = { t = -0.25, dir = (Vector3.new(side, 0, 0) + fu.toGoal * 0.35).Unit }
	end
end

local CELEBRATION_RUN = 0.7 -- seconds of sprint before he drops to his knees
local CELEBRATION_SPEED = 11 -- studs/s at the end of the sprint
local SLIDE_TIME = 0.75 -- seconds the slide takes to stop

function PassVisuals:_updateCelebration(receiver, c, dt: number)
	c.t += dt
	if c.t < 0 then
		receiver:moveTo(receiver.position, c.dir, dt) -- watches the ball go in first
		return
	end
	local speed
	if c.t < CELEBRATION_RUN then
		speed = CELEBRATION_SPEED * math.min(1, 0.4 + c.t / CELEBRATION_RUN)
	else
		if not c.sliding then
			c.sliding = true
			receiver:play("SLIDE")
		end
		speed = CELEBRATION_SPEED * math.max(0, 1 - (c.t - CELEBRATION_RUN) / SLIDE_TIME)
	end
	if c.sliding then
		-- Sliding on the knees, not running: move the figure directly.
		receiver.position += c.dir * speed * dt
		receiver.facing = c.dir
		receiver.speed = 0
	else
		receiver:moveTo(receiver.position + c.dir * speed * dt, c.dir, dt)
	end
end

function PassVisuals:_updateFollowUp(dt: number)
	local fu = self.followUp
	local receiver = self.mates[fu.receiver]
	-- Receiver jogs the last steps to the ball; the others turn to watch.
	if fu.celebration then
		self:_updateCelebration(receiver, fu.celebration, dt)
	else
		local towards = fu.stand - receiver.position
		local stepLen = math.min(towards.Magnitude, 9 * dt)
		local nextPos = if towards.Magnitude > 1e-3 then receiver.position + towards.Unit * stepLen else fu.stand
		receiver:moveTo(nextPos, fu.toGoal, dt)
	end
	for _, figure in self:_figures() do
		if figure ~= receiver then
			figure:moveTo(figure.position, flat((if fu.celebration then receiver.position else fu.spot) - figure.position), dt)
		end
	end
	-- Fade whoever stands between the camera and the goal (until the kick).
	local line = -fu.camera
	local lengthSq = line:Dot(line)
	for _, figure in self:_figures() do
		local rel = figure.position - fu.camera
		local t = rel:Dot(line) / lengthSq
		local lateral = (rel - line * t).Magnitude
		setFade(figure, if not fu.kicked and t > 0 and t < 1 and lateral < FADE_WIDTH then FADE else 0)
	end
end

function PassVisuals:_setBall(position: Vector3)
	local base = CFrame.new(position) * self.ballRotation
	for _, entry in self.ballParts do
		entry[1].CFrame = base * entry[2]
	end
	self.ballPosition = position
end

function PassVisuals:_placeRing(ring, position: Vector3)
	ring.part.CFrame = CFrame.new(position.X, 0.06, position.Z)
end

-- New episode: everyone back on their marks for this situation.
function PassVisuals:reset(layout)
	self.token += 1
	self.layout = layout
	self.clock = 0
	self.frozen = false
	self.replay = nil
	self.highlight = nil
	self:_endFollowUp()
	self.ballRotation = CFrame.identity
	local origin = layout.origin
	self:_setBall(origin + Vector3.new(0, BALL_RADIUS, 0))
	local toGoal = Vector3.new(0, 0, -1)
	self.aimFacing = toGoal
	self.passer:play(nil)
	self.passer:place(origin - toGoal * 1.5 + Vector3.new(-0.7, 0, 0), toGoal)
	for i, mate in self.mates do
		local at = layout.teammates[i]
		mate:play(nil)
		mate:place(at, flat(origin - at))
		self:_placeRing(self.mateRings[i], at)
		self.mateRings[i].part.Parent = self.folder
	end
	self.defender:play(nil)
	self.defender:place(PassPhysics.patrolAt(layout.defender, 0), flat(origin - PassPhysics.patrolAt(layout.defender, 0)))
	self.defenderZone.part.Parent = self.folder
	self:updateAiming(false, nil, 0, false)
end

-- Seconds since this episode was shown, stopped at the moment of the pass (sent to the server).
function PassVisuals:clockTime(): number
	return self.clock
end

-- Pulses one teammate's ring (the tutorial's target), or none.
function PassVisuals:setHighlight(index: number?)
	self.highlight = index
end

-- target: the drag point on the ground while holding (nil = not aiming).
function PassVisuals:updateAiming(enabled: boolean, target: Vector3?, power: number, holding: boolean)
	local layout = self.layout
	local show = enabled and holding and target ~= nil and layout ~= nil
	self.targetRing.part.Parent = if show then self.folder else nil
	for _, dot in self.dots do
		dot.Transparency = 1
	end
	self.aimTarget = if show then target else nil
	if not show then
		return
	end
	local origin = layout.origin
	local delta = flat((target :: Vector3) - origin)
	local length = delta.Magnitude
	if length < 1e-3 then
		return
	end
	local dir = delta / length
	self.aimFacing = dir
	self:_placeRing(self.targetRing, origin + delta)
	-- Dotted line from the ball to the drop point; gold within reach, lilac when too short to pass.
	local tooShort = length < PassConfig.Ball.MinRange
	local count = math.clamp(math.floor(length / 2.2), 2, LINE_DOTS)
	for i, dot in self.dots do
		if i <= count then
			local p = origin + dir * (length * i / (count + 1))
			dot.CFrame = CFrame.new(p.X, 0.08, p.Z) * CFrame.Angles(0, 0, math.pi / 2)
			dot.Color = if tooShort then LILAC else GOLD
			dot.Transparency = 0.15 + 0.5 * i / count
		end
	end
	self.targetRing.stroke.Color = if tooShort then LILAC else GOLD
	self.targetRing.frame.BackgroundColor3 = if tooShort then LILAC else GOLD
end

function PassVisuals:onPassReleased()
	self.frozen = true
	self.passer:play("KICK")
	self:updateAiming(false, nil, 0, false)
	for _, mate in self.mates do
		mate:play(nil)
	end
end

-- Replays the server's pass. onDecisive runs when the result is clear on screen.
function PassVisuals:playPass(result, onDecisive: () -> ())
	self.replay = {
		token = self.token,
		result = result,
		t = 0,
		onDecisive = onDecisive,
		decided = false,
		reacted = false,
	}
	self.defenderZone.part.Parent = nil
end

function PassVisuals:_updateReplay(dt: number)
	local replay = self.replay
	local result = replay.result
	local step = result.sampleStep
	replay.t += dt
	local t = replay.t

	local ball = trackAt(result.ball, step, t)
	local previous = self.ballPosition
	local position = Vector3.new(ball.X, BALL_RADIUS, ball.Z)
	-- Rolling: spin about the axis perpendicular to the motion.
	local moved = flat(position - previous)
	if moved.Magnitude > 1e-4 then
		local axis = Vector3.yAxis:Cross(moved.Unit)
		self.ballRotation = CFrame.fromAxisAngle(axis, moved.Magnitude / BALL_RADIUS) * self.ballRotation
	end
	self:_setBall(position)

	local defender = trackAt(result.defender, step, t)
	local defenderVelocity = trackAt(result.defender, step, t + 0.05) - defender
	local facing = if defenderVelocity.Magnitude > 0.05 then defenderVelocity else (position - defender)
	self.defender:moveTo(defender, facing, dt)

	for i, mate in self.mates do
		local home = self.layout.teammates[i]
		if result.receiver == i and result.receiverTrack then
			mate:moveTo(trackAt(result.receiverTrack, step, t), flat(position - mate.position), dt)
		else
			mate:moveTo(home, flat(position - home), dt)
		end
	end
	self.passer:moveTo(self.passer.position, flat(position - self.passer.position), dt)

	-- Reactions just before the decisive moment, so the pose lands with the ball.
	if not replay.reacted and t >= result.eventTime - 0.12 then
		replay.reacted = true
		local detail = result.detail
		local receiver = result.receiver and self.mates[result.receiver]
		if detail == "GOOD" and receiver then
			receiver:play("TRAP")
		elseif detail == "INTERCEPTED" then
			self.defender:play("LUNGE")
		elseif detail == "TOO_HARD" and receiver then
			receiver:play("LUNGE")
		end
	end
	if not replay.decided and t >= result.eventTime then
		replay.decided = true
		-- A good pass is just received (the TRAP above); celebrating is for goals.
		if result.detail == "INTERCEPTED" then
			task.delay(0.6, function()
				if self.replay == replay then
					self.defender:play("CHEER")
				end
			end)
		end
		replay.onDecisive()
	end
end

-- Per-frame: camera, the defender's patrol, idle players and the replay.
function PassVisuals:update(dt: number)
	if not self.active or not self.layout then
		return
	end
	if self.followUp then
		self:_updateFollowUp(dt)
		self.passer:update(dt)
		for _, mate in self.mates do
			mate:update(dt)
		end
		self.defender:update(dt)
		return
	end
	local camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	local target = CFrame.lookAt(PassConfig.Camera.Position, PassConfig.Camera.LookAt)
	local fov = PassConfig.Camera.FieldOfView
	if self.blendT < 1 then
		self.blendT = math.min(1, self.blendT + dt / CAMERA_BLEND)
		local k = self.blendT * self.blendT * (3 - 2 * self.blendT)
		camera.CFrame = self.blendFrom:Lerp(target, k)
		camera.FieldOfView = self.blendFov + (fov - self.blendFov) * k
	else
		camera.CFrame = target
		camera.FieldOfView = fov
	end

	local layout = self.layout
	local origin = layout.origin
	if self.replay and self.replay.token == self.token then
		self:_updateReplay(dt)
	else
		if not self.frozen then
			self.clock += dt
		end
		local def = PassPhysics.patrolAt(layout.defender, self.clock)
		self.defender:moveTo(def, flat(self.ballPosition - def), if self.frozen then 0 else dt)
		self:_placeRing(self.defenderZone, def)
		local aim = self.aimTarget
		for i, mate in self.mates do
			local home = layout.teammates[i]
			mate:moveTo(home, flat(origin - home), dt)
			-- The teammate the line points at (or the tutorial target) calls for the ball.
			local calling = (aim and flat(aim - home).Magnitude < 7) or (self.highlight == i and not self.frozen)
			if not self.frozen then
				mate:play(if calling then "WAVE" else nil)
			end
		end
		-- The passer turns to where he's about to play it.
		local facing = self.aimFacing
		local stand = origin - facing * 1.5 - facing:Cross(Vector3.yAxis) * 0.7 -- ball on his right foot
		self.passer:moveTo(stand, facing, dt)
	end

	local pulse = 0.5 + 0.5 * math.sin(os.clock() * 6)
	for i, ring in self.mateRings do
		local lit = self.highlight == i and not self.frozen
		ring.stroke.Color = if lit then GOLD else LILAC
		ring.frame.BackgroundColor3 = if lit then GOLD else LILAC
		ring.frame.BackgroundTransparency = if lit then 0.75 - 0.15 * pulse else 0.85
		ring.stroke.Thickness = if lit then 5 + 3 * pulse else 4
	end

	self.passer:update(dt)
	for _, mate in self.mates do
		mate:update(dt)
	end
	self.defender:update(dt)
end

return PassVisuals
