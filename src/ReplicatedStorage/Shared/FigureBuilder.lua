-- Blocky R15-style footballers, in the proportions of the character sheet
-- (tools/assets/source/keeper_sheet.png). Used for the goalkeeper (server) and the outfield
-- players (client). The rig faces -Z and uses the R15 Motor6D names, so KeeperAnimator /
-- FigureAnimator can drive it. Decals are filled in by the client's ImageLoader.
--   textures "kit"    the goalkeeper's sheet (Images/Keeper)
--   textures <Module> an outfield player's sheet: "PlayerMain" (you), "Teammate7", "Teammate28",
--                     "Rival9" (Images/<Module>, made by tools/assets/build_players.py)
-- Part colours follow `kit`, so a player still looks right if images are unavailable.

local FigureBuilder = {}

local IMAGE_TAG = "NfsImage" -- see ShotClient/ImageLoader
local PRINT_FONT = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.Heavy)

export type Kit = {
	skin: Color3,
	shirt: Color3,
	sleeves: Color3?, -- lower arms (default: skin)
	shorts: Color3,
	socks: Color3,
	boots: Color3,
	hands: Color3?, -- default: skin
	hair: Color3,
	print: Color3?, -- printed number and surname (players built with `number`)
	number: number?, -- printed on the chest, back and shorts (sheets with the number painted out)
	surname: string?, -- printed above the back number
}

-- Texture names per face. The rig faces -Z, so Front is the chest.
type Faces = { Front: string?, Back: string?, Left: string?, Right: string? }
local function sides(front: string?, back: string?, side: string): Faces
	return { Front = front, Back = back, Left = side, Right = side .. "R" }
end
-- Player sheets: <Part>Front / <Part>Back / <Part>Side, the head and hair with Left / Right.
local function sheet(part: string): Faces
	return { Front = part .. "Front", Back = part .. "Back", Left = part .. "Side", Right = part .. "Side" }
end
local HEAD_SHEET = { Front = "HeadFront", Back = "HeadBack", Left = "HeadLeft", Right = "HeadRight" }
local HAIR_SHEET = { Front = "HairFront", Back = "HairBack", Left = "HairLeft", Right = "HairRight" }

-- name, size, centre, kit colour, keeper faces, player faces (all at scale 1, feet on y = 0)
local PARTS: { { any } } = {
	{ "LowerTorso", Vector3.new(2, 0.6, 1), Vector3.new(0, 2.3, 0), "shorts", sides("LowerTorsoFront", "LowerTorsoBack", "LowerTorsoSide"), sheet("LowerTorso") },
	{ "UpperTorso", Vector3.new(2, 1.4, 1), Vector3.new(0, 3.3, 0), "shirt", sides("UpperTorsoFront", "UpperTorsoBack", "UpperTorsoSide"), sheet("UpperTorso") },
	{ "Head", Vector3.new(1.4, 1.25, 1.3), Vector3.new(0, 4.625, 0), "skin", sides("HeadFront", "HeadBack", "HeadSide"), HEAD_SHEET },
	{ "LeftUpperArm", Vector3.new(0.9, 1, 0.9), Vector3.new(-1.45, 3.5, 0), "shirt", sides("UpperArmSide", "UpperArmSide", "UpperArmSide"), sheet("LeftUpperArm") },
	{ "LeftLowerArm", Vector3.new(0.85, 0.75, 0.85), Vector3.new(-1.45, 2.625, 0), "sleeves", sides("LowerArmSide", "LowerArmSide", "LowerArmSide"), sheet("LeftLowerArm") },
	{ "LeftHand", Vector3.new(0.95, 0.75, 0.95), Vector3.new(-1.45, 1.875, 0), "hands", sides("GloveSide", "GloveSide", "GloveSide"), sheet("LeftHand") },
	{ "RightUpperArm", Vector3.new(0.9, 1, 0.9), Vector3.new(1.45, 3.5, 0), "shirt", sides("UpperArmSide", "UpperArmSide", "UpperArmSide"), sheet("RightUpperArm") },
	{ "RightLowerArm", Vector3.new(0.85, 0.75, 0.85), Vector3.new(1.45, 2.625, 0), "sleeves", sides("LowerArmSide", "LowerArmSide", "LowerArmSide"), sheet("RightLowerArm") },
	{ "RightHand", Vector3.new(0.95, 0.75, 0.95), Vector3.new(1.45, 1.875, 0), "hands", sides("GloveSide", "GloveSide", "GloveSide"), sheet("RightHand") },
	{ "LeftUpperLeg", Vector3.new(0.98, 1.05, 0.98), Vector3.new(-0.5, 1.475, 0), "shorts", sides("LeftUpperLegFront", "LeftUpperLegBack", "UpperLegSide"), sheet("LeftUpperLeg") },
	{ "LeftLowerLeg", Vector3.new(0.9, 0.6, 0.9), Vector3.new(-0.5, 0.65, 0), "socks", sides("LeftLowerLegFront", "LeftLowerLegBack", "LowerLegSide"), sheet("LeftLowerLeg") },
	{ "LeftFoot", Vector3.new(1, 0.35, 1.2), Vector3.new(-0.5, 0.175, -0.1), "boots", {}, {} },
	{ "RightUpperLeg", Vector3.new(0.98, 1.05, 0.98), Vector3.new(0.5, 1.475, 0), "shorts", sides("RightUpperLegFront", "RightUpperLegBack", "UpperLegSide"), sheet("RightUpperLeg") },
	{ "RightLowerLeg", Vector3.new(0.9, 0.6, 0.9), Vector3.new(0.5, 0.65, 0), "socks", sides("RightLowerLegFront", "RightLowerLegBack", "LowerLegSide"), sheet("RightLowerLeg") },
	{ "RightFoot", Vector3.new(1, 0.35, 1.2), Vector3.new(0.5, 0.175, -0.1), "boots", {}, {} },
}

-- joint name, parent part, child part, joint position (scale 1)
local JOINTS = {
	{ "Root", "HumanoidRootPart", "LowerTorso", Vector3.new(0, 2.6, 0) },
	{ "Waist", "LowerTorso", "UpperTorso", Vector3.new(0, 2.6, 0) },
	{ "Neck", "UpperTorso", "Head", Vector3.new(0, 4, 0) },
	{ "LeftShoulder", "UpperTorso", "LeftUpperArm", Vector3.new(-1.45, 3.8, 0) },
	{ "LeftElbow", "LeftUpperArm", "LeftLowerArm", Vector3.new(-1.45, 3, 0) },
	{ "LeftWrist", "LeftLowerArm", "LeftHand", Vector3.new(-1.45, 2.25, 0) },
	{ "RightShoulder", "UpperTorso", "RightUpperArm", Vector3.new(1.45, 3.8, 0) },
	{ "RightElbow", "RightUpperArm", "RightLowerArm", Vector3.new(1.45, 3, 0) },
	{ "RightWrist", "RightLowerArm", "RightHand", Vector3.new(1.45, 2.25, 0) },
	{ "LeftHip", "LowerTorso", "LeftUpperLeg", Vector3.new(-0.5, 2, 0) },
	{ "LeftKnee", "LeftUpperLeg", "LeftLowerLeg", Vector3.new(-0.5, 0.95, 0) },
	{ "LeftAnkle", "LeftLowerLeg", "LeftFoot", Vector3.new(-0.5, 0.35, 0) },
	{ "RightHip", "LowerTorso", "RightUpperLeg", Vector3.new(0.5, 2, 0) },
	{ "RightKnee", "RightUpperLeg", "RightLowerLeg", Vector3.new(0.5, 0.95, 0) },
	{ "RightAnkle", "RightLowerLeg", "RightFoot", Vector3.new(0.5, 0.35, 0) },
}

local function makePart(model: Model, name: string, size: Vector3, position: Vector3, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = CFrame.new(position)
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Parent = model
	return part
end

local function addDecal(part: BasePart, face: string, image: string)
	local decal = Instance.new("Decal")
	decal.Name = "Kit" .. face
	decal.Face = Enum.NormalId[face]
	decal:SetAttribute("Image", image)
	decal:AddTag(IMAGE_TAG)
	decal.Parent = part
end

-- Where the painted-out numbers were on the PlayerMain sheet, as fractions of the face.
local PRINTS = {
	{ part = "UpperTorso", face = Enum.NormalId.Front, name = "ChestNumber", box = { 0.29, 0.34, 0.42, 0.64 } },
	{ part = "UpperTorso", face = Enum.NormalId.Back, name = "BackNumber", box = { 0.18, 0.3, 0.64, 0.7 } },
	{ part = "LeftUpperLeg", face = Enum.NormalId.Front, name = "ShortsNumber", box = { 0.4, 0.1, 0.52, 0.58 } },
}

local function printLabel(gui: Instance, name: string, box: { number }, text: string, color: Color3): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.AnchorPoint = Vector2.new(0.5, 0.5) -- so a UIScale pops it in place
	label.Position = UDim2.fromScale(box[1] + box[3] / 2, box[2] + box[4] / 2)
	label.Size = UDim2.fromScale(box[3], box[4])
	label.BackgroundTransparency = 1
	label.FontFace = PRINT_FONT
	label.Text = text
	label.TextScaled = true
	label.TextColor3 = color
	label.Parent = gui
	return label
end

-- Number on the chest, back and shorts, surname across the shoulders.
local function addPrints(parts: { [string]: BasePart }, kit: Kit)
	local color = kit.print or Color3.fromRGB(238, 232, 246)
	local guis = {}
	for _, spec in PRINTS do
		local key = spec.part .. spec.face.Name
		local gui = guis[key]
		if not gui then
			gui = Instance.new("SurfaceGui")
			gui.Name = "Print" .. spec.face.Name
			gui.Face = spec.face
			gui.LightInfluence = 1
			gui.Parent = parts[spec.part]
			guis[key] = gui
		end
		local label = printLabel(gui, spec.name, spec.box, tostring(kit.number or ""), color)
		label:SetAttribute("KitNumber", true)
	end
	local surname = printLabel(guis.UpperTorsoBack, "Surname", { 0.03, 0.01, 0.94, 0.3 }, kit.surname or "", color)
	surname:SetAttribute("KitSurname", true)
end

-- Builds a footballer standing on y = 0 and facing -Z. Returns the model and the height of its
-- root above the ground.
function FigureBuilder.build(name: string, kit: Kit, scale: number, textures: string): (Model, number)
	local model = Instance.new("Model")
	model.Name = name
	local keeper = textures == "kit"
	local imageSet = if keeper then "Keeper" else textures
	local colors = {
		skin = kit.skin,
		shirt = kit.shirt,
		sleeves = kit.sleeves or kit.skin,
		shorts = kit.shorts,
		socks = kit.socks,
		boots = kit.boots,
		hands = kit.hands or kit.skin,
	}

	local root = makePart(model, "HumanoidRootPart", Vector3.new(2, 2, 1), Vector3.new(0, 3, 0), kit.shirt)
	root.Transparency = 1
	root.Anchored = true -- anchors the whole rig; animators move it with PivotTo
	model.PrimaryPart = root

	local parts: { [string]: BasePart } = { HumanoidRootPart = root }
	for _, spec in PARTS do
		local part = makePart(model, spec[1], spec[2], spec[3], colors[spec[4]])
		for face, image in (if keeper then spec[5] else spec[6]) do
			addDecal(part, face, imageSet .. "/" .. image)
		end
		parts[spec[1]] = part
	end

	-- Hair: a cap over the top of the head; the face and back textures already show the fringe.
	local head = parts.Head
	local hair = makePart(model, "Hair", Vector3.new(1.5, 0.34, 1.42), head.Position + Vector3.new(0, 0.74, 0.03), kit.hair)
	local hairFaces: Faces = if keeper then { Front = "Hair", Back = "Hair", Left = "Hair", Right = "Hair" } else HAIR_SHEET
	for face, image in pairs(hairFaces) do
		addDecal(hair, face, imageSet .. "/" .. image)
	end
	local hairWeld = Instance.new("WeldConstraint")
	hairWeld.Part0 = head
	hairWeld.Part1 = hair
	hairWeld.Parent = hair

	if kit.number then
		addPrints(parts, kit)
	end

	for _, joint in JOINTS do
		local part0, part1 = parts[joint[2]], parts[joint[3]]
		local motor = Instance.new("Motor6D")
		motor.Name = joint[1]
		motor.Part0 = part0
		motor.Part1 = part1
		motor.C0 = CFrame.new(joint[4] - part0.Position)
		motor.C1 = CFrame.new(joint[4] - part1.Position)
		motor.Parent = part1
	end

	model:ScaleTo(scale)
	local box, size = model:GetBoundingBox()
	local rootHeight = root.Position.Y - (box.Position.Y - size.Y / 2)
	model:PivotTo(CFrame.new(0, rootHeight, 0))
	return model, rootHeight
end

-- Changes the printed number ("" for none) and surname of a model built with kit.number.
function FigureBuilder.setPrints(model: Model, number: number | string, surname: string)
	for _, d in model:GetDescendants() do
		if d:IsA("TextLabel") then
			if d:GetAttribute("KitNumber") then
				d.Text = tostring(number)
			elseif d:GetAttribute("KitSurname") then
				d.Text = surname
			end
		end
	end
end

return FigureBuilder
