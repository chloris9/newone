-- Building blocks for the career menus in the same purple "pixel UI kit" style as ShotHud:
-- palette, fonts, glowing panels, gold/violet buttons, club crests, star ratings, text fields,
-- toggles and the viewport scaler.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local UiKit = {}

local rgb = Color3.fromRGB
UiKit.rgb = rgb
UiKit.NAVY = rgb(18, 11, 36)
UiKit.PANEL_TOP = rgb(43, 18, 80)
UiKit.PANEL_BOTTOM = rgb(27, 15, 51)
UiKit.VIOLET = rgb(90, 47, 194)
UiKit.GLOW = rgb(123, 77, 255)
UiKit.LILAC = rgb(190, 168, 255)
UiKit.RED = rgb(255, 45, 85)
UiKit.RED_LIGHT = rgb(255, 150, 170)
UiKit.GOLD = rgb(255, 191, 31)
UiKit.GOLD_LIGHT = rgb(255, 226, 120)
UiKit.LIME = rgb(170, 240, 40)
UiKit.ORANGE = rgb(255, 159, 10)
UiKit.LIP = rgb(178, 84, 0)
UiKit.CREAM = rgb(247, 236, 214)
UiKit.INK = rgb(18, 6, 31)
UiKit.SHADOW = rgb(46, 16, 92)
UiKit.WHITE = Color3.new(1, 1, 1)

local MONTSERRAT = "rbxasset://fonts/families/Montserrat.json"
UiKit.FONT_HEAVY = Font.new(MONTSERRAT, Enum.FontWeight.Heavy, Enum.FontStyle.Italic)
UiKit.FONT_BOLD = Font.new(MONTSERRAT, Enum.FontWeight.Bold, Enum.FontStyle.Italic)
UiKit.FONT_MEDIUM = Font.new(MONTSERRAT, Enum.FontWeight.Medium)
UiKit.FONT_PRINT = Font.new(MONTSERRAT, Enum.FontWeight.Heavy) -- shirt lettering

local NAVY, VIOLET, GLOW, LILAC, GOLD, GOLD_LIGHT = UiKit.NAVY, UiKit.VIOLET, UiKit.GLOW, UiKit.LILAC, UiKit.GOLD, UiKit.GOLD_LIGHT
local INK, CREAM, WHITE, SHADOW, ORANGE, LIP, RED = UiKit.INK, UiKit.CREAM, UiKit.WHITE, UiKit.SHADOW, UiKit.ORANGE, UiKit.LIP, UiKit.RED

function UiKit.create(className: string, props: { [string]: any }): any
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
local create = UiKit.create

function UiKit.frame(props: { [string]: any }): Frame
	props.BorderSizePixel = 0
	if props.BackgroundTransparency == nil then
		props.BackgroundTransparency = 0
	end
	return create("Frame", props)
end
local frame = UiKit.frame

function UiKit.text(props: { [string]: any }): TextLabel
	props.BackgroundTransparency = 1
	props.RichText = true
	props.FontFace = props.FontFace or UiKit.FONT_HEAVY
	props.TextColor3 = props.TextColor3 or CREAM
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	return create("TextLabel", props)
end
local text = UiKit.text

function UiKit.corner(parent: Instance, radius: number?)
	create("UICorner", { CornerRadius = if radius then UDim.new(0, radius) else UDim.new(1, 0), Parent = parent })
end
local corner = UiKit.corner

function UiKit.stroke(parent: Instance, color: Color3, thickness: number, transparency: number?): UIStroke
	return create("UIStroke", {
		Color = color,
		Thickness = thickness,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = parent,
	})
end
local stroke = UiKit.stroke

-- Text outline; mitred joins keep the chunky pixel-kit corners.
function UiKit.outline(label: TextLabel | TextBox, thickness: number, color: Color3?): UIStroke
	return create("UIStroke", {
		Color = color or INK,
		Thickness = thickness,
		LineJoinMode = Enum.LineJoinMode.Miter,
		Parent = label,
	})
end
local outline = UiKit.outline

function UiKit.sizeLimit(label: TextLabel, maxSize: number)
	label.TextScaled = true
	create("UITextSizeConstraint", { MaxTextSize = maxSize, MinTextSize = 8, Parent = label })
end

-- Outlined title with a hard drop shadow (a sibling label underneath).
function UiKit.bigText(props: { [string]: any }, thickness: number, offset: Vector2, maxSize: number?): (TextLabel, TextLabel)
	local shadowProps = table.clone(props)
	shadowProps.Name = (props.Name or "Text") .. "Shadow"
	shadowProps.TextColor3 = SHADOW
	shadowProps.Position = (props.Position or UDim2.new()) + UDim2.fromOffset(offset.X, offset.Y)
	shadowProps.Text = string.gsub(props.Text or "", "<[^>]+>", "")
	local shadow = text(shadowProps)
	outline(shadow, thickness)
	local main = text(table.clone(props))
	outline(main, thickness)
	if maxSize then
		UiKit.sizeLimit(shadow, maxSize)
		UiKit.sizeLimit(main, maxSize)
	end
	return main, shadow
end

-- Dark purple panel: vertical gradient, violet border and a soft glow from stacked strokes.
function UiKit.panel(props: { [string]: any }, radius: number, glowColor: Color3?): (Frame, { UIStroke }, UIStroke)
	props.BackgroundTransparency = 1
	local root = frame(props)
	local glows = {}
	for _, layer in { { 4, 0.7 }, { 9, 0.84 }, { 16, 0.93 } } do
		local halo = frame({ Name = "Glow", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 0, Parent = root })
		corner(halo, radius)
		table.insert(glows, stroke(halo, glowColor or GLOW, layer[1], layer[2]))
	end
	local bg = frame({ Name = "Background", Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, BackgroundTransparency = 0.04, ZIndex = 0, Parent = root })
	corner(bg, radius)
	create("UIGradient", { Color = ColorSequence.new(UiKit.PANEL_TOP, UiKit.PANEL_BOTTOM), Rotation = 90, Parent = bg })
	local border = stroke(bg, VIOLET, 2)
	frame({
		Name = "Sheen",
		Position = UDim2.new(0, radius, 0, 3),
		Size = UDim2.new(1, -radius * 2, 0, 2),
		BackgroundColor3 = LILAC,
		BackgroundTransparency = 0.7,
		ZIndex = 0,
		Parent = root,
	})
	return root, glows, border
end

-- Decorative "////" slashes from the reference panels.
function UiKit.slashes(parent: Instance, position: UDim2, size: number, color: Color3)
	text({ Name = "Slashes", Position = position, Size = UDim2.fromOffset(size * 2.2, size), TextSize = size, Text = "////", TextColor3 = color, TextTransparency = 0.75, Parent = parent })
end

-- Small rounded tag: icon + text on navy with a coloured border.
function UiKit.chip(parent: Instance, props: { [string]: any }, value: string, color: Color3): (Frame, TextLabel)
	props.Size = props.Size or UDim2.fromOffset(0, 28)
	props.AutomaticSize = props.AutomaticSize or Enum.AutomaticSize.X
	props.BackgroundColor3 = props.BackgroundColor3 or NAVY
	props.Parent = parent
	local c = frame(props)
	corner(c, 8)
	stroke(c, color, 2)
	create("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), Parent = c })
	local label = text({ Name = "Label", Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, Text = value, TextSize = 14, Parent = c })
	outline(label, 1.5)
	return c, label
end

export type Button = {
	button: TextButton,
	body: Frame,
	label: TextLabel,
	sub: TextLabel?,
	shine: Frame,
	shineTween: Tween,
	setText: (Button, string, string?) -> (),
	setEnabled: (Button, boolean) -> (),
	playShine: (Button) -> (),
	enabled: boolean,
}

local STYLES = {
	primary = { face = { rgb(255, 214, 74), ORANGE }, lip = LIP, text = INK },
	secondary = { face = { rgb(150, 110, 255), VIOLET }, lip = rgb(40, 16, 96), text = CREAM },
	danger = { face = { rgb(255, 120, 140), RED }, lip = rgb(120, 10, 40), text = CREAM },
}

-- Gold primary / violet secondary / red danger button: dark lip below, gradient face clipped by
-- a CanvasGroup with a moving shine. `sub` adds a small second line under the label.
function UiKit.button(parent: Instance, props: { [string]: any }, labelText: string, onActivated: () -> (), style: string?, sub: string?): Button
	local look = STYLES[style or "primary"]
	local height = props.Size and props.Size.Y.Offset or 52
	local faceHeight = height - 6
	props.BackgroundTransparency = 1
	props.AutoButtonColor = false
	props.Text = ""
	props.Parent = parent
	local button = create("TextButton", props)

	local lip = frame({ Name = "Lip", Position = UDim2.fromOffset(0, 6), Size = UDim2.new(1, 0, 0, faceHeight), BackgroundColor3 = look.lip, Parent = button })
	corner(lip, 9)
	stroke(lip, INK, 2.5)
	local body = frame({ Name = "Body", Size = UDim2.new(1, 0, 0, faceHeight), BackgroundTransparency = 1, Parent = button })
	local face = create("CanvasGroup", { Name = "Face", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, Parent = body })
	corner(face, 9)
	local fill = frame({ Name = "Fill", Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, Parent = face })
	create("UIGradient", { Color = ColorSequence.new(look.face[1], look.face[2]), Rotation = 90, Parent = fill })
	frame({ Name = "Sheen", Size = UDim2.new(1, 0, 0.42, 0), BackgroundColor3 = WHITE, BackgroundTransparency = 0.72, Parent = face })
	local shine = frame({
		Name = "Shine",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(-0.3, 0.5),
		Size = UDim2.new(0, 34, 2, 0),
		Rotation = 22,
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.45,
		Parent = face,
	})
	local edge = frame({ Name = "Outline", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Parent = body })
	corner(edge, 9)
	stroke(edge, INK, 2.5)

	local labelSize = if sub then UDim2.new(1, -20, 0.62, 0) else UDim2.new(1, -16, 1, 0)
	local label = text({
		Name = "Label",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, if sub then 0.06 else 0),
		Size = labelSize,
		Text = labelText,
		TextSize = props.TextSize or (if faceHeight >= 46 then 24 else 20),
		TextColor3 = look.text,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = body,
	})
	if look.text == INK then
		outline(label, 1.5, GOLD_LIGHT).Transparency = 0.4
	else
		outline(label, 2)
	end
	local subLabel = nil
	if sub then
		subLabel = text({
			Name = "Sub",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, 0.6),
			Size = UDim2.new(1, -20, 0.32, 0),
			Text = sub,
			TextSize = 14,
			FontFace = UiKit.FONT_BOLD,
			TextColor3 = look.text,
			TextTransparency = 0.15,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = body,
		})
	end
	local dim = frame({ Name = "Disabled", Size = UDim2.new(1, 0, 1, 6), BackgroundColor3 = INK, BackgroundTransparency = 0.45, Visible = false, ZIndex = 5, Parent = button })
	corner(dim, 9)

	local self = {
		button = button,
		body = body,
		label = label,
		sub = subLabel,
		shine = shine,
		enabled = true,
		shineTween = TweenService:Create(shine, TweenInfo.new(0.75, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, -1, false, 1.6), { Position = UDim2.fromScale(1.3, 0.5) }),
	}

	function self.setText(_, value: string, subValue: string?)
		label.Text = value
		if subLabel and subValue then
			subLabel.Text = subValue
		end
	end
	function self.setEnabled(_, enabled: boolean)
		self.enabled = enabled
		dim.Visible = not enabled
		if not enabled then
			self.shineTween:Cancel()
			shine.Position = UDim2.fromScale(-0.3, 0.5)
		end
	end
	function self.playShine(_)
		if self.enabled then
			shine.Position = UDim2.fromScale(-0.3, 0.5)
			self.shineTween:Play()
		end
	end

	local pressInfo = TweenInfo.new(0.07, Enum.EasingStyle.Quad)
	local function setPressed(pressed: boolean)
		TweenService:Create(body, pressInfo, { Position = UDim2.fromOffset(0, if pressed and self.enabled then 5 else 0) }):Play()
	end
	button.MouseButton1Down:Connect(function()
		setPressed(true)
	end)
	button.MouseButton1Up:Connect(function()
		setPressed(false)
	end)
	button.MouseLeave:Connect(function()
		setPressed(false)
	end)
	button.Activated:Connect(function()
		if self.enabled then
			onActivated()
		end
	end)
	return self :: any
end

-- Round club badge: shirt-to-shorts gradient, ink rim and the club's letters.
function UiKit.crest(parent: Instance, props: { [string]: any }, club): Frame
	local size = props.Size and props.Size.X.Offset or 56
	props.BackgroundColor3 = WHITE
	props.Parent = parent
	local badge = frame(props)
	corner(badge)
	create("UIGradient", { Color = ColorSequence.new(club.shirt, club.shorts), Rotation = 125, Parent = badge })
	stroke(badge, INK, 2.5)
	local ring = frame({ Name = "Ring", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, -8, 1, -8), BackgroundTransparency = 1, Parent = badge })
	corner(ring)
	stroke(ring, WHITE, 1.5, 0.45)
	local letters = text({
		Name = "Letters",
		Size = UDim2.fromScale(1, 1),
		Text = club.short,
		TextSize = math.floor(size * 0.36),
		TextColor3 = WHITE,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = badge,
	})
	outline(letters, 2)
	return badge
end

-- Five stars filled in half steps (rating 0..5).
function UiKit.stars(parent: Instance, props: { [string]: any }, rating: number, starSize: number): Frame
	props.BackgroundTransparency = 1
	props.Size = props.Size or UDim2.fromOffset(starSize * 5 + 4 * 2, starSize)
	props.Parent = parent
	local row = frame(props)
	create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = row })
	for i = 1, 5 do
		local slot = frame({ Name = "Star" .. i, LayoutOrder = i, Size = UDim2.fromOffset(starSize, starSize), BackgroundTransparency = 1, Parent = row })
		local back = text({ Size = UDim2.fromScale(1, 1), Text = "★", TextSize = starSize, TextColor3 = SHADOW, TextXAlignment = Enum.TextXAlignment.Center, Parent = slot })
		outline(back, 1.5)
		local fill = math.clamp(rating - (i - 1), 0, 1)
		if fill > 0 then
			local clip = frame({ Name = "Fill", Size = UDim2.fromScale(fill, 1), BackgroundTransparency = 1, ClipsDescendants = true, Parent = slot })
			local gold = text({ Size = UDim2.fromOffset(starSize, starSize), Text = "★", TextSize = starSize, TextColor3 = GOLD, TextXAlignment = Enum.TextXAlignment.Center, Parent = clip })
			outline(gold, 1.5)
		end
	end
	return row
end

-- Navy input field; the border turns gold while typing.
function UiKit.textBox(parent: Instance, props: { [string]: any }, placeholder: string): TextBox
	local holder = frame({ Name = (props.Name or "Field") .. "Holder", Position = props.Position, Size = props.Size, BackgroundColor3 = NAVY, Parent = parent })
	corner(holder, 8)
	local border = stroke(holder, VIOLET, 2)
	frame({ Name = "Bevel", Position = UDim2.fromOffset(6, 3), Size = UDim2.new(1, -12, 0, 2), BackgroundColor3 = WHITE, BackgroundTransparency = 0.9, Parent = holder })
	local box = create("TextBox", {
		Name = props.Name or "Field",
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -24, 1, 0),
		BackgroundTransparency = 1,
		ClearTextOnFocus = false,
		Text = "",
		PlaceholderText = placeholder,
		PlaceholderColor3 = LILAC,
		TextColor3 = CREAM,
		TextSize = props.TextSize or 20,
		FontFace = UiKit.FONT_BOLD,
		TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left,
		Parent = holder,
	})
	box.Focused:Connect(function()
		border.Color = GOLD
	end)
	box.FocusLost:Connect(function()
		border.Color = VIOLET
	end)
	return box
end

-- On/off pill. onChanged(value) fires on taps; set(value) updates without firing.
function UiKit.toggle(parent: Instance, props: { [string]: any }, value: boolean, onChanged: (boolean) -> ())
	props.Size = props.Size or UDim2.fromOffset(76, 34)
	props.BackgroundColor3 = NAVY
	props.AutoButtonColor = false
	props.Text = ""
	props.BorderSizePixel = 0
	props.Parent = parent
	local pill = create("TextButton", props)
	corner(pill)
	local border = stroke(pill, VIOLET, 2)
	local knob = frame({ Name = "Knob", AnchorPoint = Vector2.new(0, 0.5), Size = UDim2.fromOffset(26, 26), BackgroundColor3 = CREAM, Parent = pill })
	corner(knob)
	stroke(knob, INK, 2)
	local state = text({ Name = "State", Size = UDim2.fromScale(1, 1), TextSize = 12, TextXAlignment = Enum.TextXAlignment.Center, Parent = pill })
	outline(state, 1.5)
	create("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), Parent = state })
	local toggle = { value = value }
	function toggle.set(_, on: boolean)
		toggle.value = on
		pill.BackgroundColor3 = if on then rgb(92, 150, 20) else NAVY
		border.Color = if on then UiKit.LIME else VIOLET
		state.Text = if on then "ВКЛ" else "ВЫКЛ"
		state.TextXAlignment = if on then Enum.TextXAlignment.Left else Enum.TextXAlignment.Right
		TweenService:Create(knob, TweenInfo.new(0.15, Enum.EasingStyle.Quad), { Position = if on then UDim2.new(1, -30, 0.5, 0) else UDim2.new(0, 4, 0.5, 0) }):Play()
	end
	pill.Activated:Connect(function()
		toggle:set(not toggle.value)
		onChanged(toggle.value)
	end)
	toggle:set(value)
	return toggle
end

-- Keeps every registered UIScale at the viewport scale: as big as `layoutSize` (design units of
-- the largest screen) can be while still fitting, at most 1.15, then MENU_SCALE of that (the menus
-- are drawn about 20% smaller than the space allows). boost: "large interface".
local MENU_SCALE = 0.8
function UiKit.scaler(gui: ScreenGui, layoutSize: Vector2)
	local scaler = { scales = {} :: { UIScale }, boost = 1, scale = 1 }
	function scaler.rescale(_)
		local size = gui.AbsoluteSize
		if size.X < 1 or size.Y < 1 then
			return
		end
		local fit = math.min((size.X - 40) / layoutSize.X, (size.Y - 24) / layoutSize.Y)
		local scale = math.max(math.min(fit, 1.15) * MENU_SCALE, 0.4)
		if scaler.boost ~= 1 then
			scale = math.max(math.min(scale * scaler.boost, fit), 0.5)
		end
		scaler.scale = scale
		for _, uiScale in scaler.scales do
			uiScale.Scale = scale
		end
	end
	function scaler.add(_, target: GuiObject): UIScale
		local uiScale = create("UIScale", { Parent = target })
		table.insert(scaler.scales, uiScale)
		uiScale.Scale = scaler.scale
		return uiScale
	end
	function scaler.setBoost(_, boost: number)
		scaler.boost = boost
		scaler:rescale()
	end
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		scaler:rescale()
	end)
	scaler:rescale()
	return scaler
end

function UiKit.screenGui(name: string, displayOrder: number): ScreenGui
	return create("ScreenGui", {
		Name = name,
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = displayOrder,
		Parent = Players.LocalPlayer:WaitForChild("PlayerGui"),
	})
end

-- Pop-in for a panel: its nested UIScale grows from `from` to 1 with an overshoot.
function UiKit.pop(uiScale: UIScale, from: number?)
	uiScale.Scale = from or 0.85
	TweenService:Create(uiScale, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

return UiKit
