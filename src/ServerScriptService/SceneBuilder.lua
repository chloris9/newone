-- Builds the evening stadium at runtime: striped pitch and markings, goal with net, LED boards,
-- a two-tier stand with crowd, floodlights, a city skyline, a sunset backdrop and dusk lighting.
-- Goal dimensions come from ShotConfig so the visuals always match the geometry the server uses.
--
-- Framed for the fixed shot camera (ShotConfig.Camera): inside the pitch area there are only
-- flat ground details and the goal; the stand fills the band above the goal and the sky,
-- floodlights and skyline show above the stand roof.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ShotConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ShotConfig"))

local Goal = ShotConfig.Goal
local Arena = ShotConfig.Arena
local CameraConfig = ShotConfig.Camera
local VERTICAL = CFrame.Angles(0, 0, math.pi / 2) -- cylinder parts are long along X

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

-- Palette from the New Football Star UI kit.
local NAVY = rgb(18, 11, 36)
local PURPLE = rgb(43, 18, 80)
local VIOLET = rgb(90, 47, 194)
local VIOLET_BRIGHT = rgb(123, 77, 255)
local RED = rgb(255, 45, 85)
local GOLD = rgb(255, 191, 31)
local CREAM = rgb(247, 236, 214)
local PINK = rgb(255, 79, 163)
local WHITE = Color3.new(1, 1, 1)

local GRASS_A = rgb(58, 128, 60)
local GRASS_B = rgb(50, 114, 54)
local GRASS_EDGE = rgb(42, 96, 47)
local STEP_A = rgb(43, 18, 80)
local STEP_B = rgb(36, 15, 66)
local AISLE = rgb(74, 44, 120)
local HEAVY_ITALIC = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.Heavy, Enum.FontStyle.Italic)

local SEED = 7404 -- fixed so the crowd, skyline and clouds look the same every session

-- Pitch
local PITCH_HALF_WIDTH = 120
local STRIPE_DEPTH = 8
local PITCH_BACK = -24 -- a stripe boundary lands on the goal line
local PITCH_FRONT = 104

-- Stand behind the goal (z is negative behind the goal line).
local STAND_HALF_WIDTH = 105
local STAND_FRONT_Z = Arena.BoardZ - 3 -- walkway between the boards and the stand
local STAND_WALL_HEIGHT = 4.8
local AISLES = { -56, -20, 20, 56 }
local AISLE_WIDTH = 2.4
local SEAT_SPACING = 1.65

local CROWD_SHIRTS = { VIOLET, VIOLET, VIOLET_BRIGHT, RED, RED, GOLD, CREAM, PINK, PURPLE, WHITE, rgb(255, 140, 40) }
local CROWD_SKIN = { rgb(240, 196, 150), rgb(214, 160, 112), rgb(160, 104, 66), rgb(104, 64, 40) }
local WINDOW_COLOURS = { GOLD, GOLD, CREAM, rgb(255, 214, 140), PINK, VIOLET_BRIGHT }
local BUILDING_COLOURS = { rgb(34, 16, 64), rgb(43, 18, 80), rgb(28, 14, 54), rgb(52, 24, 96) }

-- Horizontal half-width the shot camera sees at depth z on screens up to 2.25:1, so crowd
-- blocks are only spent where they can appear.
local VIEW_SLOPE = math.tan(math.rad(CameraConfig.FieldOfView / 2)) * 2.25
local function visibleHalfWidth(z: number): number
	return (CameraConfig.Position.Z - z) * VIEW_SLOPE
end

local SceneBuilder = {}

-- Decorative, anchored, no collisions: nothing in Stage 1 relies on Roblox physics.
-- Shadows are opt-in so the low dusk sun cannot throw the stand's shadow over the goal.
local function makePart(props: { [string]: any }): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Material = Enum.Material.SmoothPlastic
	local parent = props.Parent
	for key, value in props do
		if key ~= "Parent" then
			(part :: any)[key] = value
		end
	end
	part.Parent = parent
	return part
end

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

local function folder(name: string, parent: Instance): Folder
	return create("Folder", { Name = name, Parent = parent })
end

local function corner(parent: Instance)
	create("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = parent })
end

-- Thin axis-aligned bar between two points.
local function bar(parent: Instance, name: string, from: Vector3, to: Vector3, thickness: number, color: Color3): Part
	local delta = to - from
	return makePart({
		Name = name,
		Size = Vector3.new(math.abs(delta.X) + thickness, math.abs(delta.Y) + thickness, math.abs(delta.Z) + thickness),
		CFrame = CFrame.new((from + to) / 2),
		Color = color,
		Parent = parent,
	})
end

-- The default "Baseplate" template has a baseplate at ground level (flickers through the
-- pitch) and a SpawnLocation in the goal mouth. Removed for this play session only.
local function clearDefaultTemplate()
	for _, child in workspace:GetChildren() do
		if child:IsA("SpawnLocation") or (child.Name == "Baseplate" and child:IsA("BasePart")) then
			child:Destroy()
		end
	end
end

type LedStyle = { from: Color3, to: Color3, textColor: Color3, text: string }

local IMAGE_TAG = "NfsImage" -- see ShotClient/ImageLoader
local BOARD_IMAGES = { "Wide", "NfsShield", "StarBall" }

-- Self-lit LED panel drawn on the face pointing at the pitch (+Z).
local function ledFace(part: BasePart, style: LedStyle, pixelsPerStud: number, textHeight: number, image: string?, tiles: number?)
	local gui = create("SurfaceGui", {
		Face = Enum.NormalId.Back,
		SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
		PixelsPerStud = pixelsPerStud,
		LightInfluence = 0,
		Brightness = 1.6,
		Parent = part,
	})
	-- The inset leaves a dark seam between neighbouring panels.
	local panel = create("Frame", {
		Name = "Panel",
		Position = UDim2.fromOffset(3, 3),
		Size = UDim2.new(1, -6, 1, -6),
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		Parent = gui,
	})
	create("UIGradient", { Color = ColorSequence.new(style.from, style.to), Rotation = 90, Parent = panel })
	create("Frame", {
		Name = "Shine",
		Size = UDim2.fromScale(1, 0.14),
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.82,
		BorderSizePixel = 0,
		Parent = panel,
	})
	create("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.54),
		Size = UDim2.fromScale(0.92, textHeight),
		BackgroundTransparency = 1,
		RichText = true,
		TextScaled = true,
		FontFace = HEAVY_ITALIC,
		TextColor3 = style.textColor,
		TextStrokeColor3 = NAVY,
		TextStrokeTransparency = 0.15,
		Text = style.text,
		Parent = panel,
	})
	if image then
		-- Banner artwork from Images/Banners.lua; the client fills it in and shows it (ImageLoader).
		-- tiles > 1 repeats the image across the panel (the long balcony ribbon).
		local art = create("ImageLabel", {
			Name = "Art",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			ScaleType = if tiles then Enum.ScaleType.Tile else Enum.ScaleType.Stretch,
			TileSize = UDim2.fromScale(1 / (tiles or 1), 1),
			Visible = false,
			ZIndex = 2,
			Parent = panel,
		})
		art:SetAttribute("Image", "Banners/" .. image)
		art:AddTag(IMAGE_TAG)
	end
end

local BOARD_STYLES: { LedStyle } = {
	{ from = VIOLET_BRIGHT, to = PURPLE, textColor = CREAM, text = 'NEW FOOTBALL <font color="#FF2D55">STAR</font> <font color="#FFBF1F">★</font>' },
	{ from = GOLD, to = rgb(255, 138, 20), textColor = NAVY, text = '<font color="#FF2D55">★</font> SHOOTING DRILL' },
	{ from = RED, to = rgb(140, 12, 60), textColor = CREAM, text = 'NFS <font color="#FFBF1F">★</font>' },
	{ from = PURPLE, to = NAVY, textColor = GOLD, text = "PLAY ▶" },
	{ from = NAVY, to = VIOLET, textColor = CREAM, text = '<font color="#FFBF1F">NFS</font> ARENA' },
}

local RIBBON_STYLE: LedStyle = {
	from = PINK,
	to = VIOLET,
	textColor = CREAM,
	text = 'NEW FOOTBALL STAR  <font color="#FFBF1F">★</font>  NFS  <font color="#FFBF1F">★</font>',
}

local function buildPitch(scene: Instance)
	local pitch = folder("Pitch", scene)
	makePart({
		Name = "Surround",
		Size = Vector3.new(700, 1, 700),
		CFrame = CFrame.new(0, -0.6, 0),
		Color = GRASS_EDGE,
		Material = Enum.Material.Grass,
		Parent = pitch,
	})
	local stripes = math.ceil((PITCH_FRONT - PITCH_BACK) / STRIPE_DEPTH)
	for i = 0, stripes - 1 do
		makePart({
			Name = "Stripe",
			Size = Vector3.new(PITCH_HALF_WIDTH * 2, 1, STRIPE_DEPTH),
			CFrame = CFrame.new(0, -0.5, PITCH_BACK + STRIPE_DEPTH * (i + 0.5)),
			Color = if i % 2 == 0 then GRASS_A else GRASS_B,
			Material = Enum.Material.Grass,
			Parent = pitch,
		})
	end
end

local function buildMarkings(scene: Instance)
	-- Real-world scale (3.28 studs per metre) measured from the posts, so the boxes keep their
	-- proportions if the goal is resized.
	local markings = folder("Markings", scene)
	local width = 0.45
	local hw = Goal.Width / 2
	local function line(x1: number, z1: number, x2: number, z2: number)
		makePart({
			Name = "Line",
			Size = Vector3.new(math.abs(x2 - x1) + width, 0.06, math.abs(z2 - z1) + width),
			CFrame = CFrame.new((x1 + x2) / 2, 0, (z1 + z2) / 2),
			Color = WHITE,
			Parent = markings,
		})
	end
	line(-PITCH_HALF_WIDTH + 5, 0, PITCH_HALF_WIDTH - 5, 0)
	local penaltyDepth = 54
	for _, box in { { hw + 15, 18 }, { hw + 51, penaltyDepth } } do -- six-yard box, penalty box
		local halfWidth, depth = box[1], box[2]
		line(-halfWidth, 0, -halfWidth, depth)
		line(halfWidth, 0, halfWidth, depth)
		line(-halfWidth, depth, halfWidth, depth)
	end

	-- Penalty arc: the part of a 30-stud circle around the penalty mark outside the box.
	local spotZ, radius = 36, 30
	local limit = math.acos((penaltyDepth - spotZ) / radius)
	local segments = 10
	local function arcPoint(angle: number): Vector3
		return Vector3.new(radius * math.sin(angle), 0, spotZ + radius * math.cos(angle))
	end
	for i = 0, segments - 1 do
		local a = arcPoint(-limit + 2 * limit * i / segments)
		local b = arcPoint(-limit + 2 * limit * (i + 1) / segments)
		makePart({
			Name = "Arc",
			Size = Vector3.new(width, 0.06, (b - a).Magnitude + 0.1),
			CFrame = CFrame.lookAt((a + b) / 2, b),
			Color = WHITE,
			Parent = markings,
		})
	end

	-- Glowing gold ring around the ball spot, drawn as a crisp SurfaceGui circle.
	local spot = makePart({
		Name = "BallSpotRing",
		Size = Vector3.new(5, 0.05, 5),
		CFrame = CFrame.new(0, 0.04, ShotConfig.ShotDistance),
		Transparency = 1,
		Parent = markings,
	})
	local gui = create("SurfaceGui", {
		Face = Enum.NormalId.Top,
		SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
		PixelsPerStud = 50,
		LightInfluence = 0,
		Brightness = 2,
		Parent = spot,
	})
	local glow = create("Frame", {
		Name = "Glow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -4, 1, -4),
		BackgroundColor3 = GOLD,
		BackgroundTransparency = 0.84,
		BorderSizePixel = 0,
		Parent = gui,
	})
	corner(glow)
	local ring = create("Frame", {
		Name = "Ring",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.74, 0.74),
		BackgroundColor3 = VIOLET_BRIGHT,
		BackgroundTransparency = 0.72,
		BorderSizePixel = 0,
		Parent = gui,
	})
	corner(ring)
	create("UIStroke", { Color = GOLD, Thickness = 7, Parent = ring })
	local dot = create("Frame", {
		Name = "Spot",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.16, 0.16),
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		Parent = gui,
	})
	corner(dot)
end

-- Transparent panel with a 1-stud grid of lines drawn on one face. SurfaceGui lines are
-- filtered like a texture, so they stay crisp at distance instead of flickering like thin parts.
local function netPanel(parent: Instance, name: string, size: Vector3, cframe: CFrame, face: Enum.NormalId, u: number, v: number)
	local part = makePart({ Name = name, Size = size, CFrame = cframe, Transparency = 1, Parent = parent })
	local gui = create("SurfaceGui", {
		Face = face,
		SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
		PixelsPerStud = 32,
		LightInfluence = 0.4,
		Parent = part,
	})
	create("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, BackgroundTransparency = 0.94, BorderSizePixel = 0, Parent = gui })
	local cellsU, cellsV = math.max(1, math.round(u)), math.max(1, math.round(v))
	for i = 0, cellsU do
		create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(i / cellsU, 0),
			Size = UDim2.new(0, 3, 1, 0),
			BackgroundColor3 = WHITE,
			BackgroundTransparency = 0.25,
			BorderSizePixel = 0,
			Parent = gui,
		})
	end
	for j = 0, cellsV do
		create("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.fromScale(0, j / cellsV),
			Size = UDim2.new(1, 0, 0, 3),
			BackgroundColor3 = WHITE,
			BackgroundTransparency = 0.25,
			BorderSizePixel = 0,
			Parent = gui,
		})
	end
	return part
end

local function buildGoal(scene: Instance)
	local goal = Instance.new("Model")
	goal.Name = "Goal"

	local W, H, D = Goal.Width, Goal.Height, Goal.NetDepth
	local hw = W / 2
	local postX = hw + Goal.PostRadius
	local postLength = H + 2 * Goal.PostRadius
	local diameter = 2 * Goal.PostRadius
	for _, side in { -1, 1 } do
		makePart({
			Name = if side < 0 then "LeftPost" else "RightPost",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(postLength, diameter, diameter),
			CFrame = CFrame.new(side * postX, postLength / 2, 0) * VERTICAL,
			Color = WHITE,
			Reflectance = 0.05,
			CastShadow = true,
			Parent = goal,
		})
	end
	makePart({
		Name = "Crossbar",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(W + 4 * Goal.PostRadius, diameter, diameter),
		CFrame = CFrame.new(0, H + Goal.PostRadius, 0),
		Color = WHITE,
		Reflectance = 0.05,
		CastShadow = true,
		Parent = goal,
	})

	-- Box frame holding the net: back uprights and top, side rails and ground bars.
	local support = rgb(222, 222, 230)
	local function rod(from: Vector3, to: Vector3)
		bar(goal, "Support", from, to, 0.18, support)
	end
	rod(Vector3.new(-hw, 0, -D), Vector3.new(-hw, H, -D))
	rod(Vector3.new(hw, 0, -D), Vector3.new(hw, H, -D))
	rod(Vector3.new(-hw, H, -D), Vector3.new(hw, H, -D))
	rod(Vector3.new(-hw, H, 0), Vector3.new(-hw, H, -D))
	rod(Vector3.new(hw, H, 0), Vector3.new(hw, H, -D))
	rod(Vector3.new(-hw, 0.05, -D), Vector3.new(hw, 0.05, -D))
	rod(Vector3.new(-hw, 0.05, 0), Vector3.new(-hw, 0.05, -D))
	rod(Vector3.new(hw, 0.05, 0), Vector3.new(hw, 0.05, -D))

	local net = folder("Net", goal)
	-- Faces point into the goal, towards the camera.
	netPanel(net, "NetBack", Vector3.new(W, H, 0.05), CFrame.new(0, H / 2, -D), Enum.NormalId.Back, W, H)
	netPanel(net, "NetLeft", Vector3.new(0.05, H, D), CFrame.new(-hw, H / 2, -D / 2), Enum.NormalId.Right, D, H)
	netPanel(net, "NetRight", Vector3.new(0.05, H, D), CFrame.new(hw, H / 2, -D / 2), Enum.NormalId.Left, D, H)
	netPanel(net, "NetTop", Vector3.new(W, 0.05, D), CFrame.new(0, H, -D / 2), Enum.NormalId.Bottom, W, D)

	goal.Parent = scene
end

-- LED advertising boards. Their front face is the plane the ball bounces off (Arena.BoardZ).
local function buildBoards(scene: Instance)
	local boards = folder("Boards", scene)
	local height = Arena.BoardHeight
	local width = 20
	for index = -5, 5 do
		local board = makePart({
			Name = "Board",
			Size = Vector3.new(width, height, 1),
			CFrame = CFrame.new(index * width, height / 2, Arena.BoardZ - 0.5),
			Color = NAVY,
			Parent = boards,
		})
		ledFace(board, BOARD_STYLES[index % #BOARD_STYLES + 1], 30, 0.6, BOARD_IMAGES[index % #BOARD_IMAGES + 1])
	end
	makePart({
		Name = "TopStrip",
		Size = Vector3.new(width * 11, 0.18, 0.9),
		CFrame = CFrame.new(0, height + 0.09, Arena.BoardZ - 0.5),
		Color = VIOLET_BRIGHT,
		Material = Enum.Material.Neon,
		Parent = boards,
	})
	makePart({
		Name = "Walkway",
		Size = Vector3.new(STAND_HALF_WIDTH * 2, 0.1, Arena.BoardZ - 1 - STAND_FRONT_Z),
		CFrame = CFrame.new(0, 0.02, (Arena.BoardZ - 1 + STAND_FRONT_Z) / 2),
		Color = NAVY,
		Material = Enum.Material.Concrete,
		Parent = boards,
	})
end

local function inAisle(x: number): boolean
	for _, aisle in AISLES do
		if math.abs(x - aisle) < AISLE_WIDTH / 2 + 0.6 then
			return true
		end
	end
	return false
end

-- One fan: shirt block with a head on top.
local function addFan(crowd: Instance, rng: Random, x: number, floorY: number, z: number)
	local body = rng:NextNumber(1.0, 1.5)
	local shirt = CROWD_SHIRTS[rng:NextInteger(1, #CROWD_SHIRTS)]
	makePart({ Name = "Fan", Size = Vector3.new(1.25, body, 0.8), CFrame = CFrame.new(x, floorY + body / 2, z), Color = shirt, Parent = crowd })
	makePart({
		Name = "Head",
		Size = Vector3.new(0.7, 0.7, 0.7),
		CFrame = CFrame.new(x, floorY + body + 0.35, z),
		Color = CROWD_SKIN[rng:NextInteger(1, #CROWD_SKIN)],
		Parent = crowd,
	})
end

-- Stepped seating rows with fans; returns the z behind the last row and its floor height.
local function buildTier(stand: Instance, crowd: Instance, rng: Random, frontZ: number, baseY: number, rows: number, tread: number, rise: number): (number, number)
	local z, top = frontZ, baseY
	for row = 1, rows do
		top += rise
		local centreZ = z - tread / 2
		makePart({
			Name = "Step",
			Size = Vector3.new(STAND_HALF_WIDTH * 2, top, tread),
			CFrame = CFrame.new(0, top / 2, centreZ),
			Color = if row % 2 == 0 then STEP_A else STEP_B,
			Parent = stand,
		})
		for _, x in AISLES do
			makePart({ Name = "AisleStep", Size = Vector3.new(AISLE_WIDTH, 0.06, tread), CFrame = CFrame.new(x, top + 0.03, centreZ), Color = AISLE, Parent = stand })
		end
		local halfWidth = math.min(visibleHalfWidth(centreZ) + 4, STAND_HALF_WIDTH - 1)
		local x = -halfWidth
		while x <= halfWidth do
			-- A few empty seats keep the crowd from reading as a solid wall.
			if not inAisle(x) and rng:NextNumber() > 0.07 then
				addFan(crowd, rng, x + rng:NextNumber(-0.15, 0.15), top, centreZ + rng:NextNumber(-0.25, 0.2))
			end
			x += SEAT_SPACING
		end
		z -= tread
	end
	return z, top
end

local function neonStrip(parent: Instance, name: string, y: number, z: number, color: Color3, halfWidth: number?)
	local width = 2 * (halfWidth or STAND_HALF_WIDTH)
	makePart({ Name = name, Size = Vector3.new(width, 0.28, 0.3), CFrame = CFrame.new(0, y, z), Color = color, Material = Enum.Material.Neon, Parent = parent })
end

local function buildStand(scene: Instance, rng: Random)
	local stand = folder("Stand", scene)
	local crowd = folder("Crowd", stand)
	local width = STAND_HALF_WIDTH * 2

	makePart({
		Name = "FrontWall",
		Size = Vector3.new(width, STAND_WALL_HEIGHT, 1),
		CFrame = CFrame.new(0, STAND_WALL_HEIGHT / 2, STAND_FRONT_Z - 0.5),
		Color = PURPLE,
		Parent = stand,
	})
	neonStrip(stand, "WallGlow", STAND_WALL_HEIGHT - 0.1, STAND_FRONT_Z - 0.1, PINK)

	-- Lower tier.
	local lowerBack, lowerTop = buildTier(stand, crowd, rng, STAND_FRONT_Z - 1, STAND_WALL_HEIGHT, 5, 1.9, 0.8)

	-- Balcony front of the upper tier with an LED ribbon, lifted clear of the lower crowd's heads.
	local ribbonBottom, ribbonHeight = lowerTop + 2.2, 1.8
	makePart({
		Name = "BalconyWall",
		Size = Vector3.new(width, ribbonBottom, 0.8),
		CFrame = CFrame.new(0, ribbonBottom / 2, lowerBack - 0.4),
		Color = NAVY,
		Parent = stand,
	})
	for index = -2, 2 do
		local ribbon = makePart({
			Name = "Ribbon",
			Size = Vector3.new(42, ribbonHeight, 0.8),
			CFrame = CFrame.new(index * 42, ribbonBottom + ribbonHeight / 2, lowerBack - 0.4),
			Color = NAVY,
			Parent = stand,
		})
		ledFace(ribbon, RIBBON_STYLE, 20, 0.7, "Ribbon", 4)
	end
	neonStrip(stand, "RibbonGlow", ribbonBottom + ribbonHeight + 0.14, lowerBack - 0.3, VIOLET_BRIGHT)

	-- Upper tier.
	local upperBack, upperTop = buildTier(stand, crowd, rng, lowerBack - 0.8, ribbonBottom + ribbonHeight, 4, 2, 0.85)

	-- Roof canopy over the upper tier: dark underside with lamps, neon-trimmed fascia on the front.
	-- Kept low so the sky, floodlights and skyline get the top fifth of the shot camera's view.
	local roofY = upperTop + 2.6
	local roofFront = upperBack + 5
	local roofDepth = roofFront - (upperBack - 1)
	makePart({
		Name = "BackWall",
		Size = Vector3.new(width, roofY, 1),
		CFrame = CFrame.new(0, roofY / 2, upperBack - 0.5),
		Color = NAVY,
		Parent = stand,
	})
	makePart({
		Name = "Roof",
		Size = Vector3.new(width, 0.6, roofDepth),
		CFrame = CFrame.new(0, roofY + 0.3, roofFront - roofDepth / 2),
		Color = NAVY,
		Material = Enum.Material.Metal,
		Parent = stand,
	})
	makePart({
		Name = "Fascia",
		Size = Vector3.new(width, 1.4, 0.5),
		CFrame = CFrame.new(0, roofY + 0.3, roofFront - 0.25),
		Color = PURPLE,
		Parent = stand,
	})
	neonStrip(stand, "FasciaGlowLow", roofY - 0.25, roofFront + 0.1, VIOLET_BRIGHT)
	neonStrip(stand, "FasciaGlowHigh", roofY + 0.85, roofFront + 0.1, PINK)
	for x = -80, 80, 10 do
		makePart({
			Name = "RoofLamp",
			Size = Vector3.new(2.4, 0.2, 1),
			CFrame = CFrame.new(x, roofY - 0.1, roofFront - roofDepth * 0.45),
			Color = CREAM,
			Material = Enum.Material.Neon,
			Parent = stand,
		})
	end
end

-- Floodlight towers rising above the roof, heads tilted at the penalty area.
local FLOODLIGHTS = {
	Vector3.new(-38, 28.5, -62),
	Vector3.new(38, 28.5, -62),
	Vector3.new(-66, 34.5, -100),
	Vector3.new(66, 34.5, -100),
}

local function buildFloodlights(scene: Instance)
	local lights = folder("Floodlights", scene)
	local aim = Vector3.new(0, 0, 20)
	for _, head in FLOODLIGHTS do
		local poleHeight = head.Y - 2.5
		makePart({
			Name = "Pole",
			Size = Vector3.new(1.3, poleHeight, 1.3),
			CFrame = CFrame.new(head.X, poleHeight / 2, head.Z),
			Color = PURPLE,
			Material = Enum.Material.Metal,
			Parent = lights,
		})
		local frame = CFrame.lookAt(head, aim)
		local panel = makePart({
			Name = "Head",
			Size = Vector3.new(10.5, 6.4, 1),
			CFrame = frame,
			Color = NAVY,
			Material = Enum.Material.Metal,
			Parent = lights,
		})
		makePart({
			Name = "Trim",
			Size = Vector3.new(10.9, 0.35, 1.1),
			CFrame = frame * CFrame.new(0, 3.3, 0),
			Color = VIOLET_BRIGHT,
			Material = Enum.Material.Neon,
			Parent = lights,
		})
		for col = 0, 3 do
			for row = 0, 2 do
				makePart({
					Name = "Lamp",
					Size = Vector3.new(2.1, 1.5, 0.3),
					-- Front face (-Z) of the head points at the pitch.
					CFrame = frame * CFrame.new(-3.75 + col * 2.5, -1.9 + row * 1.9, -0.55),
					Color = rgb(255, 248, 230),
					Material = Enum.Material.Neon,
					Parent = lights,
				})
			end
		end
		create("PointLight", { Brightness = 1.6, Range = 45, Color = rgb(255, 236, 214), Shadows = false, Parent = panel })
	end
end

-- Dark purple towers far behind the stadium; lit windows only where they rise above the roof.
local function buildSkyline(scene: Instance, rng: Random)
	local skyline = folder("Skyline", scene)
	local rowsOfTowers = {
		{ z = -240, minHeight = 44, maxHeight = 60 },
		{ z = -292, minHeight = 52, maxHeight = 76 },
	}
	for rowIndex, row in rowsOfTowers do
		local x = -225 + (rowIndex - 1) * 11
		while x < 225 do
			local width = rng:NextNumber(14, 30)
			local height = rng:NextNumber(row.minHeight, row.maxHeight)
			local landmark = rng:NextNumber() < 0.15
			if landmark then
				height += 14
			end
			local centreX = x + width / 2
			local z = row.z - rng:NextNumber(0, 10)
			local building = makePart({
				Name = "Building",
				Size = Vector3.new(width, height, 16),
				CFrame = CFrame.new(centreX, height / 2, z),
				Color = BUILDING_COLOURS[rng:NextInteger(1, #BUILDING_COLOURS)],
				Parent = skyline,
			})
			local gui = create("SurfaceGui", {
				Face = Enum.NormalId.Back,
				SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
				PixelsPerStud = 3,
				LightInfluence = 0,
				Brightness = 1.3,
				Parent = building,
			})
			local cols = math.floor((width - 2) / 3)
			local floors = math.floor(math.min(height - 4, 30) / 3.5)
			for f = 0, floors - 1 do
				for c = 0, cols - 1 do
					if rng:NextNumber() < 0.3 then
						create("Frame", {
							Position = UDim2.fromScale((1.6 + c * 3) / width, (2 + f * 3.5) / height),
							Size = UDim2.fromScale(1.6 / width, 2 / height),
							BackgroundColor3 = WINDOW_COLOURS[rng:NextInteger(1, #WINDOW_COLOURS)],
							BorderSizePixel = 0,
							Parent = gui,
						})
					end
				end
			end
			if landmark then
				makePart({
					Name = "Spire",
					Size = Vector3.new(0.8, 9, 0.8),
					CFrame = CFrame.new(centreX, height + 4.5, z),
					Color = PURPLE,
					Parent = skyline,
				})
				makePart({
					Name = "Beacon",
					Size = Vector3.new(1.2, 1.2, 1.2),
					CFrame = CFrame.new(centreX, height + 9.4, z),
					Color = RED,
					Material = Enum.Material.Neon,
					Parent = skyline,
				})
			end
			x += width + rng:NextNumber(3, 9)
		end
	end
end

-- Painted sunset behind the skyline. The camera is fixed, so a self-lit card gives a reliable
-- purple-to-orange sky without sky textures.
local SKY_Z, SKY_BOTTOM, SKY_TOP, SKY_HALF_WIDTH = -420, 30, 150, 300

local function buildSkyBackdrop(scene: Instance, rng: Random)
	local sky = folder("Sky", scene)
	local height = SKY_TOP - SKY_BOTTOM
	local card = makePart({
		Name = "SunsetCard",
		Size = Vector3.new(SKY_HALF_WIDTH * 2, height, 1),
		CFrame = CFrame.new(0, SKY_BOTTOM + height / 2, SKY_Z),
		Color = NAVY,
		Parent = sky,
	})
	local gui = create("SurfaceGui", {
		Face = Enum.NormalId.Back,
		SizingMode = Enum.SurfaceGuiSizingMode.FixedSize,
		CanvasSize = Vector2.new(1500, 300),
		LightInfluence = 0,
		Brightness = 1.15,
		Parent = card,
	})
	local function scaleY(y: number): number
		return (SKY_TOP - y) / height
	end
	local function scaleX(x: number): number
		return (x + SKY_HALF_WIDTH) / (SKY_HALF_WIDTH * 2)
	end
	local gradient = create("Frame", { Name = "Gradient", Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, BorderSizePixel = 0, Parent = gui })
	create("UIGradient", {
		Rotation = 90, -- keypoint 0 at the top
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, NAVY),
			ColorSequenceKeypoint.new(scaleY(124), PURPLE),
			ColorSequenceKeypoint.new(scaleY(108), VIOLET),
			ColorSequenceKeypoint.new(scaleY(96), rgb(170, 60, 190)),
			ColorSequenceKeypoint.new(scaleY(86), rgb(255, 79, 140)),
			ColorSequenceKeypoint.new(scaleY(76), rgb(255, 122, 70)),
			ColorSequenceKeypoint.new(scaleY(66), rgb(255, 170, 50)),
			ColorSequenceKeypoint.new(1, rgb(255, 214, 120)),
		}),
		Parent = gradient,
	})

	-- Setting sun peeking over the roof, right of the goal.
	for _, disc in { { size = 72, color = GOLD, transparency = 0.75 }, { size = 36, color = rgb(255, 230, 160), transparency = 0 } } do
		local sun = create("Frame", {
			Name = "Sun",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(scaleX(85), scaleY(64)),
			Size = UDim2.fromScale(disc.size / (SKY_HALF_WIDTH * 2), disc.size / height),
			BackgroundColor3 = disc.color,
			BackgroundTransparency = disc.transparency,
			BorderSizePixel = 0,
			Parent = gui,
		})
		corner(sun)
	end

	-- Blocky two-tone cloud streaks, dark above and lit by the sunset underneath.
	for _ = 1, 12 do
		local y = rng:NextNumber(84, 114)
		local x = rng:NextNumber(-280, 280)
		local length = rng:NextNumber(40, 120)
		local thickness = rng:NextNumber(2.5, 5)
		local high = y > 98
		create("Frame", {
			Name = "Cloud",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.fromScale(scaleX(x), scaleY(y)),
			Size = UDim2.fromScale(length / (SKY_HALF_WIDTH * 2), thickness / height),
			BackgroundColor3 = if high then rgb(64, 28, 128) else rgb(150, 50, 160),
			BackgroundTransparency = 0.2,
			BorderSizePixel = 0,
			Parent = gui,
		})
		create("Frame", {
			Name = "CloudLit",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(scaleX(x + length * 0.08), scaleY(y)),
			Size = UDim2.fromScale(length * 0.7 / (SKY_HALF_WIDTH * 2), 1.2 / height),
			BackgroundColor3 = if high then PINK else rgb(255, 150, 80),
			BackgroundTransparency = 0.25,
			BorderSizePixel = 0,
			Parent = gui,
		})
	end
end

-- Non-shadow floodlighting on the goal mouth and ball spot, mounted above the top of the frame.
local function buildPlayLights(scene: Instance)
	local rig = folder("PlayLights", scene)
	local lamps = {
		{ from = Vector3.new(-30, 42, 30), to = Vector3.new(0, 4, 0), brightness = 3, angle = 70 },
		{ from = Vector3.new(30, 42, 30), to = Vector3.new(0, 4, 0), brightness = 3, angle = 70 },
		{ from = Vector3.new(0, 38, 62), to = Vector3.new(0, 0, ShotConfig.ShotDistance), brightness = 2, angle = 60 },
	}
	for _, lamp in lamps do
		local anchor = makePart({
			Name = "LightRig",
			Size = Vector3.new(1, 1, 1),
			CFrame = CFrame.lookAt(lamp.from, lamp.to),
			Transparency = 1,
			Parent = rig,
		})
		create("SpotLight", {
			Face = Enum.NormalId.Front,
			Angle = lamp.angle,
			Brightness = lamp.brightness,
			Range = 60,
			Color = rgb(255, 244, 228),
			Shadows = false,
			Parent = anchor,
		})
	end
end

local function ensureChild(parent: Instance, className: string, name: string): any
	local existing = parent:FindFirstChildOfClass(className)
	if existing then
		return existing
	end
	return create(className, { Name = name, Parent = parent })
end

-- Dusk with floodlit brightness: ambient stays high so the goal and keeper read clearly.
local function setupLighting()
	Lighting.ClockTime = 17.9
	Lighting.GeographicLatitude = 20
	Lighting.Brightness = 2.4
	Lighting.Ambient = rgb(96, 82, 132)
	Lighting.OutdoorAmbient = rgb(156, 138, 190)
	Lighting.ColorShift_Top = rgb(255, 214, 180)
	Lighting.ColorShift_Bottom = rgb(90, 60, 160)
	Lighting.EnvironmentDiffuseScale = 0.5
	Lighting.EnvironmentSpecularScale = 0.6
	Lighting.ExposureCompensation = 0.2
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = 0.3

	local atmosphere = ensureChild(Lighting, "Atmosphere", "Atmosphere")
	atmosphere.Density = 0.24
	atmosphere.Offset = 0.1
	atmosphere.Color = rgb(205, 120, 190)
	atmosphere.Decay = rgb(110, 70, 170)
	atmosphere.Glare = 0.3
	atmosphere.Haze = 1.6

	local bloom = ensureChild(Lighting, "BloomEffect", "Bloom")
	bloom.Intensity = 0.9
	bloom.Size = 30
	bloom.Threshold = 1.45

	local grading = ensureChild(Lighting, "ColorCorrectionEffect", "ColorCorrection")
	grading.Saturation = 0.2
	grading.Contrast = 0.16
	grading.Brightness = 0.02
	grading.TintColor = rgb(246, 234, 255)

	local rays = ensureChild(Lighting, "SunRaysEffect", "SunRays")
	rays.Intensity = 0.02
	rays.Spread = 0.5
end

function SceneBuilder.build(): Folder
	local old = workspace:FindFirstChild("FootballScene")
	if old then
		old:Destroy()
	end
	clearDefaultTemplate()

	local rng = Random.new(SEED)
	local scene = Instance.new("Folder")
	scene.Name = "FootballScene"
	buildPitch(scene)
	buildMarkings(scene)
	buildGoal(scene)
	buildBoards(scene)
	buildStand(scene, rng)
	buildFloodlights(scene)
	buildSkyline(scene, rng)
	buildSkyBackdrop(scene, rng)
	buildPlayLights(scene)
	scene.Parent = workspace

	setupLighting()
	print(string.format("[SceneBuilder] Stadium built (%d objects)", #scene:GetDescendants()))
	return scene
end

return SceneBuilder
