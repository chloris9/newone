-- 3D side of a match moment (MomentPhysics): you, teammates #7 and #28, two or three defenders,
-- the ball, ground markers and the aiming line. Everything is local to this client and replays
-- what the server decided.
--   begin(layout)  intro: #28 plays the ball to you (RECEIVE) or you carry it forward (ON_BALL),
--                  then slow motion: pressers close in until the tackle time (onReady fires when
--                  the decision clock starts; the server starts its own clock then).
--   playPass / tackle / beginFollowUp / followUpKick / celebrate: the rest of the moment.
-- The shot itself (ball flight, keeper, net) is ShotVisuals'; this scene owns the camera until
-- a teammate's finish, which uses the shot camera.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShotConfig = require(Shared:WaitForChild("ShotConfig"))
local MomentPhysics = require(Shared:WaitForChild("MomentPhysics"))
local FigureBuilder = require(Shared:WaitForChild("FigureBuilder"))
local FigureAnimator = require(script.Parent:WaitForChild("FigureAnimator"))

local Config = MomentPhysics.Config
local BALL_RADIUS = ShotConfig.Ball.Radius
local SCALE = ShotConfig.Goalkeeper.ModelScale
local SLOW = Config.SlowMo
local LINE_DOTS = 26
local CAMERA_BLEND = 0.9
local CAMERA_FOV = 50
local HEADER_SLOWMO = 0.12 -- the cross hangs at the header until the finish arrives
local MAX_DEFENDERS = 3
local DEFENDER_NUMBERS = { 4, 5, 3 }

local rgb = Color3.fromRGB
local WHITE = Color3.new(1, 1, 1)
local GOLD = rgb(255, 191, 31)
local LILAC = rgb(190, 168, 255)
local RED = rgb(255, 45, 85)
local SKIN = rgb(214, 132, 82)
local HAIR = rgb(52, 32, 26)
-- Kits are painted on from the character sheets; these colours only show if images are unavailable.
local NAVY = rgb(26, 36, 110)
local TEAM_KIT = { skin = SKIN, shirt = NAVY, shorts = NAVY, socks = NAVY, boots = rgb(236, 232, 244), hair = HAIR }
local BLACK = rgb(24, 18, 26)
local OPPONENT_KIT = { skin = SKIN, shirt = BLACK, shorts = BLACK, socks = BLACK, boots = rgb(236, 232, 244), hair = HAIR, print = rgb(245, 245, 245) }
-- Numberless rival kit (numbers drawn as text) if it was generated, else the #9 sheet.
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
	local stroke = create("UIStroke", { Color = color, Thickness = 4, Parent = circle })
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

local function smooth(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

function MomentVisuals.new()
	local self = setmetatable({}, MomentVisuals)
	self.active = false
	self.token = 0
	self.phase = "IDLE"
	self.ballRotation = CFrame.identity
	self.ballPosition = Vector3.new(0, -50, 0)

	local folder = create("Folder", { Name = "MomentVisuals" })
	self.folder = folder

	local ballModel = create("Model", { Name = "Ball", Parent = folder })
	local shell = makePart({ Name = "Shell", Shape = Enum.PartType.Ball, Size = Vector3.one * BALL_RADIUS * 2, Color = WHITE, CastShadow = true, Parent = ballModel })
	self.ballParts = { { shell, CFrame.identity } }
	for _, dir in icosahedronDirections() do
		local reference = if math.abs(dir.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis
		local patch = makePart({ Name = "Panel", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.05, BALL_RADIUS * 0.66, BALL_RADIUS * 0.66), Color = rgb(28, 18, 48), Parent = ballModel })
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
		return FigureAnimator.new(model, rootHeight, SCALE)
	end
	self.me = figure("You", TEAM_KIT, "PlayerMain", 10)
	self.mates = { figure("Mate7", TEAM_KIT, "Teammate7"), figure("Mate28", TEAM_KIT, "Teammate28") }
	self.defenders = {}
	for i = 1, MAX_DEFENDERS do
		self.defenders[i] = figure("Defender" .. i, OPPONENT_KIT, DEFENDER_SHEET, if DEFENDER_SHEET == "RivalPlain" then DEFENDER_NUMBERS[i] else nil)
	end

	self.mateRings = {}
	for i = 1, 2 do
		self.mateRings[i] = groundCircle(folder, "MateRing" .. i, 3.2, LILAC, 0.85)
	end
	self.dangerRings = {}
	for i = 1, MAX_DEFENDERS do
		self.dangerRings[i] = groundCircle(folder, "Danger" .. i, Config.TackleReach, RED, 0.75)
	end
	self.targetRing = groundCircle(folder, "Target", 1.8, GOLD, 0.6)
	self.dots = {}
	for i = 1, LINE_DOTS do
		self.dots[i] = makePart({ Name = "LineDot", Shape = Enum.PartType.Ball, Size = Vector3.one * 0.55, Color = GOLD, Material = Enum.Material.Neon, Transparency = 1, Parent = folder })
	end

	-- Slow motion look: colours drain a little while you decide.
	self.grade = create("ColorCorrectionEffect", { Name = "MomentSlowMo", Enabled = false, Saturation = 0, Contrast = 0, TintColor = WHITE, Parent = Lighting })
	return self
end

-- Your number and surname on your shirt.
function MomentVisuals:setPlayer(number: number, surname: string)
	FigureBuilder.setPrints(self.me.model, number, surname)
end

function MomentVisuals:_setBall(position: Vector3)
	local base = CFrame.new(position) * self.ballRotation
	for _, entry in self.ballParts do
		entry[1].CFrame = base * entry[2]
	end
	self.ballPosition = position
end

-- Ball to a new spot, rolling (or spinning in the air) on the way.
function MomentVisuals:_moveBall(position: Vector3)
	local moved = position - self.ballPosition
	if moved.Magnitude > 1e-4 and moved.Magnitude < 20 then
		local ground = flat(moved)
		if ground.Magnitude > 1e-4 then
			local axis = Vector3.yAxis:Cross(ground.Unit)
			self.ballRotation = CFrame.fromAxisAngle(axis, ground.Magnitude / BALL_RADIUS) * self.ballRotation
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

function MomentVisuals:_setSlowMo(on: boolean)
	self.slowmo = on
	local grade = self.grade
	grade.Enabled = true
	TweenService:Create(grade, TweenInfo.new(0.35), {
		Saturation = if on then -0.35 else 0,
		Contrast = if on then 0.12 else 0,
		TintColor = if on then rgb(225, 232, 255) else WHITE,
	}):Play()
end

-- Behind you, high enough to see the goal, your teammates and the defenders.
local function cameraFor(layout): (Vector3, Vector3)
	local c = layout.carrier
	local position = c - layout.toGoal * 30 + Vector3.new(-c.X * 0.25, 24, 0)
	local look = c:Lerp(Vector3.new(0, 0, 8), 0.55)
	return position, look
end

-- Where you stand with the ball on your right foot.
local function standFor(ball: Vector3, facing: Vector3): Vector3
	return flat(ball) - facing * 1.5 - facing:Cross(Vector3.yAxis) * 0.7
end

function MomentVisuals:enter()
	self.active = true
	self.folder.Parent = workspace
end

function MomentVisuals:exit()
	self.active = false
	self.phase = "IDLE"
	self.token += 1
	self.folder.Parent = nil
	if self.slowmo then
		self:_setSlowMo(false)
	end
end

-- New moment. Returns the intro length; onReady fires when the decision clock starts.
function MomentVisuals:begin(layout, onReady: (() -> ())?): number
	self:enter()
	self.token += 1
	self.layout = layout
	self.phase = "INTRO"
	self.clock = 0
	self.decision = 0
	self.onReady = onReady
	self.replay = nil
	self.followUp = nil
	self.tackled = false
	self.released = false
	self.aim = nil
	self.aimTarget = nil
	self.introKicked, self.introTrapped = false, false
	self.smoothLook = nil
	self.timeScale = 1
	self.ballRotation = CFrame.identity
	local toGoal = layout.toGoal
	self.intro = MomentPhysics.intro(layout)

	local camera = workspace.CurrentCamera
	self.blendFrom, self.blendFov, self.blendT = camera.CFrame, camera.FieldOfView, 0
	self.cameraOn = true
	self.cameraLook = nil

	local carrier = layout.carrier
	if layout.kind == "RECEIVE" then
		self.me:place(standFor(carrier, toGoal), flat((layout.passerFrom :: Vector3) - carrier))
		self.introBallFrom = layout.passerFrom + flat(carrier - layout.passerFrom).Unit * 1.6
	else
		local from = carrier - toGoal * 7
		self.me:place(standFor(from, toGoal), toGoal)
		self.introBallFrom = from
	end
	self:_setBall(self.introBallFrom + Vector3.new(0, BALL_RADIUS, 0))
	self.me:play(nil)
	for i, mate in self.mates do
		local at = MomentPhysics.mateAt(layout, i, 0)
		mate:play(nil)
		mate:place(at, flat(carrier - at))
		self.mateRings[i].part.Parent = self.folder
		placeRing(self.mateRings[i], at)
	end
	if layout.kind == "RECEIVE" then
		-- #28 stands behind the ball, about to play it.
		local passer = self.mates[2]
		local dir = flat(carrier - layout.passerFrom).Unit
		passer:place(flat(self.introBallFrom) - dir * 1.5 - dir:Cross(Vector3.yAxis) * 0.7, dir)
	end
	for i, defender in self.defenders do
		local spec = layout.defenders[i]
		defender.model.Parent = if spec then self.folder else nil
		self.dangerRings[i].part.Parent = nil
		if spec then
			local at = MomentPhysics.defenderAt(layout, i, 0)
			defender:play(nil)
			defender:place(at, flat(carrier - at))
		end
	end
	self:updateAiming(false)
	return self.intro
end

-- Decision seconds (sent with the input; the server checks it against the tackle).
function MomentVisuals:decisionTime(): number
	return self.decision
end

-- 1 = all the time in the world, 0 = tackled; nil outside the decision.
function MomentVisuals:pressure(): number?
	if self.phase ~= "DECIDE" or not self.layout then
		return nil
	end
	return 1 - self.decision / self.layout.tackleTime
end

function MomentVisuals:isDeciding(): boolean
	return self.phase == "DECIDE"
end

-- Aiming line for a pass (dots on the grass) or a cross (an arc in the air).
function MomentVisuals:updateAiming(enabled: boolean, action: string?, target: Vector3?, holding: boolean?)
	local layout = self.layout
	local show = enabled and holding and target ~= nil and layout ~= nil and action ~= "SHOT"
	self.aimTarget = if show then target else nil
	self.targetRing.part.Parent = if show then self.folder else nil
	for _, dot in self.dots do
		dot.Transparency = 1
	end
	if not show then
		if enabled and layout and action == "SHOT" and holding then
			self.aim = flat(-layout.carrier).Unit
		end
		return
	end
	local origin = layout.carrier
	local delta = flat((target :: Vector3) - origin)
	local length = delta.Magnitude
	if length < 1e-3 then
		return
	end
	local dir = delta / length
	self.aim = dir
	placeRing(self.targetRing, origin + delta)
	local high = action == "CROSS"
	local minRange = if high then Config.CrossMinRange else 8
	local tooShort = length < minRange
	local color = if tooShort then LILAC elseif high then rgb(120, 220, 255) else GOLD
	local count = math.clamp(math.floor(length / 2), 3, LINE_DOTS)
	for i, dot in self.dots do
		if i <= count then
			local u = i / (count + 1)
			local p
			if high then
				local flightTime = MomentPhysics.crossFlight(length)
				p = MomentPhysics.crossBallAt(origin, dir, length, u * flightTime)
			else
				p = origin + dir * (length * u) + Vector3.new(0, 0.2, 0)
			end
			dot.CFrame = CFrame.new(p)
			dot.Color = color
			dot.Transparency = 0.1 + 0.5 * u
		end
	end
	self.targetRing.stroke.Color = color
	self.targetRing.frame.BackgroundColor3 = color
end

-- You played it: time back to normal, the kick, and everyone waits for the server.
function MomentVisuals:onReleased(action: string)
	if self.phase ~= "DECIDE" then
		return
	end
	self.released = true
	self.phase = "RELEASED"
	self:_setSlowMo(false)
	self:updateAiming(false)
	local layout = self.layout
	local facing = self.aim or flat(-layout.carrier).Unit
	if action == "SHOT" then
		facing = flat(-layout.carrier).Unit
	end
	self.me.facing = facing
	self.me:play("KICK")
	for _, ring in self.dangerRings do
		ring.part.Parent = nil
	end
end

-- The shot's replay (ShotVisuals) takes the ball.
function MomentVisuals:onShotPlayed()
	self.phase = "SHOT"
	self:hideBall()
end

-- Too slow: the presser takes the ball. Safe to call twice (local clock, then the server).
function MomentVisuals:tackle(tackler: number?)
	if self.tackled or not self.layout then
		return
	end
	self.tackled = true
	self.phase = "TACKLE"
	self.clock = 0
	self:_setSlowMo(false)
	self:updateAiming(false)
	local index = tackler or self.layout.tackler
	local defender = self.defenders[index]
	self.tackleBy = defender
	defender:play("LUNGE")
	self.me:play("STUMBLE")
	local side = flat(defender.position - self.layout.carrier)
	self.tackleBallTo = flat(self.layout.carrier) + (if side.Magnitude > 1e-3 then side.Unit else Vector3.xAxis) * 4 + self.layout.toGoal:Cross(Vector3.yAxis) * 2
	for _, ring in self.dangerRings do
		ring.part.Parent = nil
	end
end

-- Replays the server's pass or cross. onDecisive runs when the result is clear on screen (a
-- received cross: as the header is about to happen, which then waits in slow motion).
function MomentVisuals:playPass(result, onDecisive: () -> ())
	self.phase = "REPLAY"
	self.replay = { token = self.token, result = result, t = 0, onDecisive = onDecisive, decided = false, reacted = false }
	for _, ring in self.mateRings do
		ring.part.Parent = nil
	end
end

function MomentVisuals:_updateReplay(dt: number)
	local replay = self.replay
	local result = replay.result
	local step = result.sampleStep
	local headerHold = result.detail == "GOOD" and result.header
	if headerHold and replay.t >= result.eventTime - 0.35 then
		dt *= HEADER_SLOWMO
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

	local lead = if headerHold or (result.detail == "CLEARED") then 0.35 else 0.12
	if not replay.reacted and t >= result.eventTime - lead then
		replay.reacted = true
		local detail = result.detail
		local receiver = result.receiver and self.mates[result.receiver]
		local interceptor = result.interceptor and self.defenders[result.interceptor]
		if detail == "GOOD" and receiver then
			receiver:play(if result.header then "HEADER" else "TRAP")
		elseif interceptor then
			interceptor:play(if detail == "CLEARED" then "HEADER" else "LUNGE")
		elseif detail == "TOO_HARD" and receiver then
			receiver:play("LUNGE")
		end
	end
	local decideAt = if headerHold then result.eventTime - 0.3 else result.eventTime
	if not replay.decided and t >= decideAt then
		replay.decided = true
		if result.detail == "INTERCEPTED" or result.detail == "CLEARED" then
			task.delay(0.6, function()
				if self.replay == replay and result.interceptor then
					self.defenders[result.interceptor]:play("CHEER")
				end
			end)
		end
		replay.onDecisive()
	end
	-- Camera drifts after the ball.
	self.cameraLook = ball
end

-- The teammate's finish after your pass or cross: he lines up (a header is struck where he met
-- the cross), the shot camera takes over for a ground shot.
function MomentVisuals:beginFollowUp(receiver: number, spot: Vector3, header: boolean)
	local mate = self.mates[receiver]
	if not (self.active and mate and self.layout) then
		return
	end
	self.replay = nil
	self.phase = "FOLLOWUP"
	local toGoal = flat(-spot)
	toGoal = if toGoal.Magnitude > 1e-3 then toGoal.Unit else Vector3.new(0, 0, -1)
	self.followUp = { receiver = receiver, spot = spot, header = header, toGoal = toGoal, stand = flat(spot) - toGoal * 1.3 - toGoal:Cross(Vector3.yAxis) * 0.8 }
	self:hideBall() -- ShotVisuals' ball takes over
	for _, ring in self.mateRings do
		ring.part.Parent = nil
	end
	if header then
		mate:place(flat(spot) - toGoal * 0.4, toGoal)
		self.cameraOn = true
		self.cameraLook = Vector3.new(0, 3, 0)
	else
		self.cameraOn = false -- ShotVisuals' shot camera
	end
end

function MomentVisuals:followUpKick()
	local fu = self.followUp
	if fu then
		fu.kicked = true
		self.mates[fu.receiver]:play(if fu.header then "HEADER" else "KICK")
	end
end

-- who: "ME" or a teammate index. The scorer celebrates (random), the others cheer.
function MomentVisuals:celebrate(who: any)
	local scorer = if who == "ME" then self.me else self.mates[who]
	if not scorer then
		return
	end
	local token = self.token
	task.delay(0.3, function()
		if self.active and self.token == token then
			-- Towards the crowd on his side, half facing the camera.
			local side = if scorer.position.X >= 0 then 1 else -1
			scorer.facing = (Vector3.new(side, 0, 0) + Vector3.new(0, 0, 1) * 0.6).Unit
			scorer:celebrate()
		end
	end)
	for _, figure in { self.me, self.mates[1], self.mates[2] } do
		if figure ~= scorer then
			figure:play("CHEER")
		end
	end
end

local function slowMove(animator, position: Vector3, facing: Vector3, dt: number)
	-- Real run cycle played slowly: moved by dt, animated by dt * SLOW.
	animator:moveTo(position, facing, dt * SLOW)
end

function MomentVisuals:update(dt: number)
	if not self.active or not self.layout then
		return
	end
	local layout = self.layout
	local carrier = layout.carrier
	local toGoal = layout.toGoal
	local slowFigures = {}

	if self.phase == "INTRO" then
		self.clock += dt
		local t = self.clock
		local stand = standFor(carrier, toGoal)
		if layout.kind == "RECEIVE" then
			local passer = self.mates[2]
			local kickAt, arriveAt = 0.3, self.intro - 0.55
			if t >= kickAt and not self.introKicked then
				self.introKicked = true
				passer:play("KICK")
			end
			if t < kickAt + 0.1 then
				self:_setBall(self.introBallFrom + Vector3.new(0, BALL_RADIUS, 0))
			else
				local k = math.clamp((t - kickAt - 0.1) / (arriveAt - kickAt - 0.1), 0, 1)
				local eased = 1 - (1 - k) * (1 - k)
				self:_moveBall(flat(self.introBallFrom):Lerp(flat(carrier), eased) + Vector3.new(0, BALL_RADIUS, 0))
			end
			if t >= arriveAt - 0.12 and not self.introTrapped then
				self.introTrapped = true
				self.me:play("TRAP")
			end
			local ball = self.ballPosition
			self.me:moveTo(stand, if t < arriveAt then flat(ball - stand) else toGoal, dt)
			passer:moveTo(passer.position, flat(ball - passer.position), dt)
		else
			-- A few touches forward with the ball.
			local k = smooth(t / (self.intro - 0.15))
			local from = flat(self.introBallFrom)
			local ballAt = from:Lerp(flat(carrier), k)
			local touch = math.abs(math.sin(t * 9)) * 0.6
			self:_moveBall(ballAt + toGoal * touch + Vector3.new(0, BALL_RADIUS, 0))
			self.me:moveTo(standFor(ballAt, toGoal), toGoal, dt)
		end
		for i, defender in self.defenders do
			if layout.defenders[i] then
				defender:moveTo(defender.position, flat(self.ballPosition - defender.position), dt)
			end
		end
		self.mates[1]:moveTo(self.mates[1].position, flat(self.ballPosition - self.mates[1].position), dt)
		if t >= self.intro then
			self.introKicked, self.introTrapped = false, false
			self.phase = "DECIDE"
			self.decision = 0
			self.aim = toGoal
			self:_setBall(carrier + Vector3.new(0, BALL_RADIUS, 0))
			self:_setSlowMo(true)
			for i, ring in self.dangerRings do
				local spec = layout.defenders[i]
				ring.part.Parent = if spec and spec.role == "PRESS" then self.folder else nil
			end
			if self.onReady then
				self.onReady()
			end
		end
	elseif self.phase == "DECIDE" then
		self.decision += dt
		local t = self.decision
		for i, defender in self.defenders do
			if layout.defenders[i] then
				local at = MomentPhysics.defenderAt(layout, i, t)
				slowMove(defender, at, flat(carrier - at), dt)
				slowFigures[defender] = true
				placeRing(self.dangerRings[i], at)
			end
		end
		for i, mate in self.mates do
			local at = MomentPhysics.mateAt(layout, i, t)
			local spec = layout.teammates[i]
			local running = spec.speed > 0 and flat(at - spec.to).Magnitude > 0.2
			slowMove(mate, at, if running then flat(spec.to - spec.from) else flat(carrier - at), dt)
			slowFigures[mate] = true
			placeRing(self.mateRings[i], at)
			-- The teammate the line points at calls for it.
			local calling = self.aimTarget and flat(self.aimTarget - at).Magnitude < 7
			mate:play(if calling then "WAVE" else nil)
		end
		local facing = self.aim or toGoal
		self.me:moveTo(standFor(carrier, facing), facing, dt * SLOW)
		slowFigures[self.me] = true
		local pulse = 0.5 + 0.5 * math.sin(os.clock() * 8)
		for _, ring in self.dangerRings do
			ring.frame.BackgroundTransparency = 0.8 - 0.25 * pulse * (1 - (self:pressure() or 1))
		end
		if t >= layout.tackleTime then
			self:tackle(nil)
		end
	elseif self.phase == "RELEASED" or self.phase == "SHOT" then
		for i, defender in self.defenders do
			if layout.defenders[i] then
				defender:moveTo(defender.position, flat(Vector3.zero - defender.position), dt)
			end
		end
	elseif self.phase == "TACKLE" then
		self.clock += dt
		local k = smooth(self.clock / 0.5)
		self:_moveBall(flat(carrier):Lerp(self.tackleBallTo, k) + Vector3.new(0, BALL_RADIUS, 0))
		local tackler = self.tackleBy
		if tackler and self.clock < 0.4 then
			tackler:moveTo(tackler.position:Lerp(flat(carrier), math.min(1, dt * 6)), flat(carrier - tackler.position), dt)
		end
	elseif self.phase == "REPLAY" and self.replay and self.replay.token == self.token then
		self:_updateReplay(dt)
	elseif self.phase == "FOLLOWUP" then
		local fu = self.followUp
		local mate = self.mates[fu.receiver]
		if not fu.header and not mate:isCelebrating() then
			local towards = fu.stand - mate.position
			local stepLen = math.min(towards.Magnitude, 9 * dt)
			mate:moveTo(if towards.Magnitude > 1e-3 then mate.position + towards.Unit * stepLen else fu.stand, fu.toGoal, dt)
		end
	end

	-- Camera: behind you, gliding in at the start; the shot camera takes over for a finish.
	if self.cameraOn then
		local camera = workspace.CurrentCamera
		camera.CameraType = Enum.CameraType.Scriptable
		local position, look = cameraFor(layout)
		if self.cameraLook then
			look = look:Lerp(self.cameraLook, 0.35)
		end
		self.smoothLook = if self.smoothLook then self.smoothLook:Lerp(look, math.min(1, dt * 4)) else look
		local target = CFrame.lookAt(position, self.smoothLook)
		if self.blendT < 1 then
			self.blendT = math.min(1, self.blendT + dt / CAMERA_BLEND)
			local k = smooth(self.blendT)
			camera.CFrame = self.blendFrom:Lerp(target, k)
			camera.FieldOfView = self.blendFov + (CAMERA_FOV - self.blendFov) * k
		else
			camera.CFrame = target
			camera.FieldOfView = CAMERA_FOV
		end
	end

	for _, figure in { self.me, self.mates[1], self.mates[2], table.unpack(self.defenders) } do
		figure:update(if slowFigures[figure] then dt * SLOW else dt)
	end
end

-- The server turned the input down (e.g. sent too fast): back to deciding, clock still running.
function MomentVisuals:resume()
	if self.phase ~= "RELEASED" then
		return
	end
	self.released = false
	self.phase = "DECIDE"
	self:_setSlowMo(true)
	for i, ring in self.dangerRings do
		local spec = self.layout.defenders[i]
		ring.part.Parent = if spec and spec.role == "PRESS" then self.folder else nil
	end
end

return MomentVisuals
