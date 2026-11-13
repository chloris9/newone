-- Career menus, shown before any training: main menu (new career / continue / settings), the
-- league's club picker (3 of 8 clubs open), player creation with the 3D preview in the club's kit,
-- the signed-contract card that leads to training, and the "next match" card after training.
-- The 3D stadium stays behind every screen; this module owns the camera while it is open.
--
-- Server calls go through the CareerRequest RemoteFunction (see CareerService); the server
-- validates and filters everything, the checks here only give instant feedback.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CareerConfig = require(Shared:WaitForChild("CareerConfig"))
local UiKit = require(script.Parent:WaitForChild("UiKit"))
local ImageLoader = require(script.Parent:WaitForChild("ImageLoader"))
local PlayerPreview = require(script.Parent:WaitForChild("PlayerPreview"))

local create, frame, text, corner, stroke, outline = UiKit.create, UiKit.frame, UiKit.text, UiKit.corner, UiKit.stroke, UiKit.outline
local NAVY, VIOLET, GLOW, LILAC, GOLD, LIME, RED, RED_LIGHT = UiKit.NAVY, UiKit.VIOLET, UiKit.GLOW, UiKit.LILAC, UiKit.GOLD, UiKit.LIME, UiKit.RED, UiKit.RED_LIGHT
local INK, CREAM, WHITE = UiKit.INK, UiKit.CREAM, UiKit.WHITE
local FONT_BOLD, FONT_MEDIUM = UiKit.FONT_BOLD, UiKit.FONT_MEDIUM

-- All player-facing text in one place.
local TEXT = {
	Tagline = 'КАРЬЕРА ФУТБОЛИСТА  •  <font color="#FFBF1F">ОТ НОВИЧКА ДО ЗВЕЗДЫ</font>',
	NewCareer = "НОВАЯ КАРЬЕРА",
	NewCareerSub = "Выбери клуб и создай игрока",
	Continue = "ПРОДОЛЖИТЬ КАРЬЕРУ",
	ContinueNone = "Нет сохранённой карьеры",
	ContinueSub = "%s  ·  №%d %s",
	Settings = "НАСТРОЙКИ",
	Loading = "Загрузка профиля…",
	SessionOnly = "Сохранения недоступны: прогресс останется только до выхода",
	LoadFailed = "Нет связи с сервером. Попробуй перезайти",
	-- Club picker
	ClubsTitle = "ВЫБЕРИ КЛУБ",
	League = "🏆 %s  ·  %d КЛУБОВ",
	ClubsInfo = "Твой рейтинг — %d. Пока контракт предлагают только %d клуба из %d. Расти — и топ-клубы заметят тебя!",
	ClubOpen = "ДОСТУПЕН",
	ClubPicked = "✓ ВЫБРАН",
	ClubLocked = "🔒 OVR %d+",
	ClubLockedHint = "%s пока не смотрит в твою сторону. Нужен рейтинг %d+",
	ClubPickHint = "Выбери один из доступных клубов",
	ClubChosenHint = "%s ждёт тебя!",
	Ovr = "OVR %d",
	Back = "‹  НАЗАД",
	Next = "ДАЛЕЕ  ›",
	-- Player creation
	PlayerTitle = "ТВОЙ ИГРОК",
	FirstName = "ИМЯ",
	LastName = "ФАМИЛИЯ",
	Number = "НОМЕР НА ФУТБОЛКЕ",
	FirstPlaceholder = "Например, Алекс",
	LastPlaceholder = "Например, Иванов",
	Confirm = "ПОДТВЕРДИТЬ  ›",
	Saving = "СОХРАНЯЕМ…",
	-- Signed contract
	SignedTitle = "КОНТРАКТ\nПОДПИСАН!",
	SignedPlayer = "%s %s  ·  №%d",
	SignedInfo = "Перед первым матчем — короткая тренировка: удар и пас.",
	Level = "УРОВЕНЬ %d",
	ToTraining = "НА ТРЕНИРОВКУ  ›",
	-- After training / career with training done
	TrainedTitle = "ОБУЧЕНИЕ\nПРОЙДЕНО!",
	CareerTitle = "ТВОЯ\nКАРЬЕРА",
	CareerLine = "%s %s  ·  №%d  ·  %s",
	FirstMatch = "СЛЕДУЮЩИЙ МАТЧ",
	CareerStats = "Уровень %d  ·  Матчи: %d  ·  Голы: %d  ·  Передачи: %d",
	PlayMatch = "ИГРАТЬ МАТЧ  ›",
	ToMenu = "В МЕНЮ",
	-- Settings and confirmations
	SettingsTitle = "НАСТРОЙКИ",
	Shake = "Тряска камеры при ударе",
	BigUi = "Крупный интерфейс",
	DeleteCareer = "УДАЛИТЬ КАРЬЕРУ",
	Done = "ГОТОВО",
	ReplaceTitle = "НОВАЯ КАРЬЕРА?",
	ReplaceBody = "Текущая карьера (%s, №%d %s) будет удалена, когда ты подпишешь новый контракт.",
	ReplaceYes = "НАЧАТЬ",
	DeleteTitle = "УДАЛИТЬ КАРЬЕРУ?",
	DeleteBody = "Карьеру в %s нельзя будет вернуть.",
	DeleteYes = "УДАЛИТЬ",
	Cancel = "ОТМЕНА",
	Errors = {
		FIRST_EMPTY = "Введи имя",
		FIRST_TOO_SHORT = "Имя слишком короткое",
		FIRST_TOO_LONG = "Имя — не длиннее %d символов",
		FIRST_BAD_CHARS = "В имени можно только буквы, пробел и дефис",
		LAST_EMPTY = "Введи фамилию — она будет на футболке",
		LAST_TOO_SHORT = "Фамилия слишком короткая",
		LAST_TOO_LONG = "Фамилия — не длиннее %d символов",
		LAST_BAD_CHARS = "В фамилии можно только буквы, пробел и дефис",
		BAD_NUMBER = "Номер — от 1 до 99",
		NAME_FILTERED = "Такое имя использовать нельзя. Попробуй другое",
		FILTER_FAILED = "Не удалось проверить имя. Попробуй ещё раз",
		CLUB_LOCKED = "Этот клуб пока закрыт",
		CAREER_EXISTS = "Карьера уже есть. Начни новую из главного меню",
		BUSY = "Секунду…",
		NOT_LOADED = "Профиль ещё загружается…",
		NETWORK = "Нет связи с сервером",
		Other = "Что-то пошло не так (%s)",
	},
}

local LAYOUT_SIZE = Vector2.new(920, 456) -- the biggest screen (club picker) must fit on phones
local SCREEN_SIZE = Vector2.new(900, 436)
local CARD_SIZE = Vector2.new(216, 142)
local CARD_GAP = 12
local CARD_TOP = 84

-- Camera over the training stadium (the goal is at z = 0, see ShotConfig); CREATE frames the
-- player (PlayerPreview).
local MENU_CAMERA = { from = Vector3.new(0, 9, 92), to = Vector3.new(0, 5.5, 0), fov = 36 }
local CLUBS_CAMERA = { from = Vector3.new(6, 8, 86), to = Vector3.new(0, 5.5, 0), fov = 36 }
-- The creation screen keeps the player sharp and softens the stadium with depth of field instead.
local BLUR = { MENU = 6, CREATE = 0, CLUBS = 16, NEXT = 12 }
local DEPTH = { CREATE = true }
-- Screen shade: darker on the left behind the menus, the stadium shows through on the right.
local SHADE_LEFT = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.12),
	NumberSequenceKeypoint.new(0.45, 0.55),
	NumberSequenceKeypoint.new(1, 0.85),
})

local CareerMenu = {}
CareerMenu.__index = CareerMenu

local function errorText(code: string?): string
	local message = TEXT.Errors[code or "NETWORK"]
	if not message then
		return string.format(TEXT.Errors.Other, tostring(code))
	end
	if string.find(message, "%%d") then
		return string.format(message, CareerConfig.Name.MaxLength)
	end
	return message
end

-- Keeps a TextBox to `max` characters (UTF-8 aware).
local function limitLength(box: TextBox, max: number)
	local value = box.Text
	local length = utf8.len(value)
	if length and length > max then
		box.Text = string.sub(value, 1, (utf8.offset(value, max + 1) or (#value + 1)) - 1)
	end
end

function CareerMenu.new(remote: RemoteFunction)
	local self = setmetatable({}, CareerMenu)
	self.remote = remote
	self.career = nil
	self.settings = { shake = true, bigUi = false }
	self.persistent = true
	self.loaded = false
	self.active = true
	self.busy = false
	self.replace = false
	self.selectedClub = nil
	self.onStartTraining = nil :: ((any) -> ())?
	self.onStartMatch = nil :: ((any, any) -> ())? -- (career, { homeId, awayId, moments })
	self.onSettingsChanged = nil :: ((any) -> ())?
	self.cameraMode = "MENU"
	self.clock = 0
	self.preview = PlayerPreview.new()

	local gui = UiKit.screenGui("CareerMenu", 5)
	self.gui = gui
	self.scaler = UiKit.scaler(gui, LAYOUT_SIZE)

	-- Darker on the left where the menus sit; the stadium shows through on the right.
	local shade = frame({ Name = "Shade", Position = UDim2.fromOffset(-200, -120), Size = UDim2.new(1, 400, 1, 240), BackgroundColor3 = INK, Parent = gui })
	create("UIGradient", { Transparency = SHADE_LEFT, Parent = shade })
	self.shade = shade

	self.screens = {}
	self:_buildMain()
	self:_buildClubs()
	self:_buildPlayer()
	self:_buildNextMatch()
	self:_buildOverlay()

	local camera = workspace.CurrentCamera
	self.blur = create("BlurEffect", { Name = "MenuBlur", Size = 0, Parent = camera })
	self.depth = create("DepthOfFieldEffect", {
		Name = "MenuDepth",
		FarIntensity = 0.45,
		NearIntensity = 0,
		FocusDistance = 16,
		InFocusRadius = 6,
		Parent = camera,
	})
	self.camCFrame, self.camFov = CFrame.lookAt(MENU_CAMERA.from, MENU_CAMERA.to), MENU_CAMERA.fov

	self:_show("MAIN")
	task.spawn(function()
		self:_load()
	end)
	return self
end

function CareerMenu:_request(action: string, payload: any?): { [string]: any }
	local ok, result = pcall(function()
		return self.remote:InvokeServer(action, payload)
	end)
	if not ok or typeof(result) ~= "table" then
		warn("[CareerMenu]", action, "failed:", if ok then "bad reply" else result)
		return { ok = false, error = "NETWORK" }
	end
	return result
end

-- Every screen: a full-size root, a centred holder at viewport scale and a nested pop scale.
function CareerMenu:_screen(name: string, size: Vector2, anchor: Vector2?, position: UDim2?)
	local root = frame({ Name = name, Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, Parent = self.gui })
	local holder = frame({
		Name = "Holder",
		AnchorPoint = anchor or Vector2.new(0.5, 0.5),
		Position = position or UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(size.X, size.Y),
		BackgroundTransparency = 1,
		Parent = root,
	})
	self.scaler:add(holder)
	local content = frame({ Name = "Content", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Parent = holder })
	local pop = create("UIScale", { Parent = content })
	local screen = { root = root, content = content, pop = pop }
	self.screens[name] = screen
	return screen
end

---------------------------------------------------------------- main menu

-- Left column: logo and tagline, the three buttons under them; the stadium fills the rest.
function CareerMenu:_buildMain()
	local root = frame({ Name = "MAIN", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, Parent = self.gui })
	local column = frame({ Name = "Column", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 24, 0.5, 0), Size = UDim2.fromOffset(330, 420), BackgroundTransparency = 1, Parent = root })
	self.scaler:add(column)

	-- Logo and tagline
	local logo = frame({ Name = "Logo", Size = UDim2.fromOffset(330, 136), BackgroundTransparency = 1, Parent = column })
	local embedded = ImageLoader.get("Logo/Logo")
	if embedded then
		create("ImageLabel", { Name = "LogoImage", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ImageContent = embedded, ScaleType = Enum.ScaleType.Fit, Parent = logo })
	else
		UiKit.bigText({ Name = "Wordmark", Text = 'NEW FOOTBALL <font color="#FF2D55">STAR</font> <font color="#FFBF1F">★</font>', TextSize = 36, Position = UDim2.fromOffset(4, 44), Size = UDim2.fromOffset(322, 48), Parent = logo }, 3.5, Vector2.new(3, 4))
	end
	local tagline = frame({ Name = "Tagline", Position = UDim2.fromOffset(10, 140), Size = UDim2.fromOffset(310, 26), BackgroundColor3 = NAVY, BackgroundTransparency = 0.1, Parent = column })
	corner(tagline, 6)
	stroke(tagline, VIOLET, 2)
	local accent = frame({ AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 9, 0.5, 0), Size = UDim2.fromOffset(5, 12), BackgroundColor3 = RED, Parent = tagline })
	corner(accent, 1)
	local taglineText = text({ Position = UDim2.fromOffset(20, 2), Size = UDim2.new(1, -26, 1, -4), Text = TEXT.Tagline, TextSize = 11, Parent = tagline })
	UiKit.sizeLimit(taglineText, 11)
	outline(taglineText, 1.2)

	-- Buttons
	local c = frame({ Name = "Content", Position = UDim2.fromOffset(10, 182), Size = UDim2.fromOffset(310, 236), BackgroundTransparency = 1, Parent = column })
	local pop = create("UIScale", { Parent = c })
	self.newButton = UiKit.button(c, { Name = "NewCareer", Position = UDim2.fromOffset(0, 0), Size = UDim2.fromOffset(310, 60), TextSize = 22 }, TEXT.NewCareer, function()
		self:_onNewCareer()
	end, "primary", TEXT.NewCareerSub)
	self.continueButton = UiKit.button(c, { Name = "Continue", Position = UDim2.fromOffset(0, 70), Size = UDim2.fromOffset(310, 60), TextSize = 19 }, TEXT.Continue, function()
		self:_onContinue()
	end, "secondary", TEXT.ContinueNone)
	self.settingsButton = UiKit.button(c, { Name = "Settings", Position = UDim2.fromOffset(0, 140), Size = UDim2.fromOffset(310, 46), TextSize = 19 }, "⚙  " .. TEXT.Settings, function()
		self:_openSettings()
	end, "secondary")
	self.status = text({ Name = "Status", Position = UDim2.fromOffset(2, 192), Size = UDim2.fromOffset(306, 30), Text = TEXT.Loading, TextSize = 11, FontFace = FONT_MEDIUM, TextColor3 = LILAC, TextWrapped = true, Parent = c })
	outline(self.status, 1)
	self.newButton:setEnabled(false)
	self.continueButton:setEnabled(false)

	self.screens.MAIN = { root = root, content = c, pop = pop }
end

function CareerMenu:_refreshMain()
	local career = self.career
	local club = career and CareerConfig.club(career.clubId)
	self.newButton:setEnabled(self.loaded)
	self.continueButton:setEnabled(club ~= nil)
	if career and club then
		self.continueButton:setText(TEXT.Continue, string.format(TEXT.ContinueSub, club.name, career.number, career.lastName))
	else
		self.continueButton:setText(TEXT.Continue, TEXT.ContinueNone)
	end
	if not self.loaded then
		self.status.Text = TEXT.Loading
	elseif not self.persistent then
		self.status.Text = TEXT.SessionOnly
	else
		self.status.Text = ""
	end
	self.deleteButton.button.Visible = career ~= nil
	if self.loaded then
		self.newButton:playShine()
	end
end

function CareerMenu:_load()
	local result
	for attempt = 1, 3 do
		result = self:_request("GET")
		if result.ok or result.error ~= "BUSY" then
			break
		end
		task.wait(attempt * 0.5)
	end
	if not result.ok then
		self.status.Text = TEXT.LoadFailed
		return
	end
	self.loaded = true
	self.career = result.career
	self.persistent = result.persistent ~= false
	if typeof(result.settings) == "table" then
		self:_applySettings(result.settings)
	end
	self:_refreshMain()
end

function CareerMenu:_onNewCareer()
	if not self.loaded then
		return
	end
	local career = self.career
	local club = career and CareerConfig.club(career.clubId)
	if career and club then
		self:_confirm(TEXT.ReplaceTitle, string.format(TEXT.ReplaceBody, club.name, career.number, career.lastName), TEXT.ReplaceYes, false, function()
			self:_startNew(true)
		end)
	else
		self:_startNew(false)
	end
end

function CareerMenu:_startNew(replace: boolean)
	self.replace = replace
	self.selectedClub = nil
	self:_refreshCards()
	self:_show("CLUBS")
end

function CareerMenu:_onContinue()
	local career = self.career
	if not career or self.busy then
		return
	end
	if career.training == "DONE" then
		self:_showNext(false)
	else
		self:_startTraining(self.continueButton)
	end
end

---------------------------------------------------------------- club picker

function CareerMenu:_buildClubs()
	local screen = self:_screen("CLUBS", SCREEN_SIZE)
	local c = screen.content
	UiKit.bigText({ Name = "Title", Text = TEXT.ClubsTitle, TextSize = 38, Position = UDim2.fromOffset(0, 0), Size = UDim2.fromOffset(520, 44), Parent = c }, 3.5, Vector2.new(3, 4))
	local league = UiKit.chip(c, { Name = "League", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 8) }, string.format(TEXT.League, CareerConfig.League.Name, #CareerConfig.Clubs), GOLD)
	league.Size = UDim2.fromOffset(0, 32)

	local openCount = 0
	for _, club in CareerConfig.Clubs do
		if club.open then
			openCount += 1
		end
	end
	local info = text({
		Name = "Info",
		Position = UDim2.fromOffset(2, 48),
		Size = UDim2.fromOffset(SCREEN_SIZE.X, 30),
		Text = string.format(TEXT.ClubsInfo, CareerConfig.StartOvr, openCount, #CareerConfig.Clubs),
		TextSize = 15,
		FontFace = FONT_BOLD,
		TextWrapped = true,
		Parent = c,
	})
	outline(info, 1.5)

	self.cards = {}
	for i, club in CareerConfig.Clubs do
		local col, row = (i - 1) % 4, (i - 1) // 4
		self.cards[club.id] = self:_buildCard(c, club, Vector2.new(col * (CARD_SIZE.X + CARD_GAP), CARD_TOP + row * (CARD_SIZE.Y + CARD_GAP)))
	end

	local footerY = CARD_TOP + 2 * CARD_SIZE.Y + CARD_GAP + 12
	UiKit.button(c, { Name = "Back", Position = UDim2.fromOffset(0, footerY), Size = UDim2.fromOffset(170, 50) }, TEXT.Back, function()
		self:_show("MAIN")
	end, "secondary")
	self.clubHint = text({
		Name = "Hint",
		Position = UDim2.fromOffset(186, footerY),
		Size = UDim2.fromOffset(SCREEN_SIZE.X - 186 - 226, 44),
		Text = TEXT.ClubPickHint,
		TextSize = 15,
		FontFace = FONT_BOLD,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = c,
	})
	outline(self.clubHint, 1.5)
	self.clubNext = UiKit.button(c, { Name = "Next", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, footerY), Size = UDim2.fromOffset(210, 50) }, TEXT.Next, function()
		if self.selectedClub then
			self:_enterPlayer()
		end
	end, "primary")
end

function CareerMenu:_buildCard(parent: Instance, club, position: Vector2)
	local button = create("TextButton", {
		Name = club.id,
		Position = UDim2.fromOffset(position.X, position.Y),
		Size = UDim2.fromOffset(CARD_SIZE.X, CARD_SIZE.Y),
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		Parent = parent,
	})
	local body, glows, border = UiKit.panel({ Name = "Card", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), Parent = button }, 12)
	local pop = create("UIScale", { Parent = body })

	UiKit.crest(body, { Name = "Crest", Position = UDim2.fromOffset(12, 12), Size = UDim2.fromOffset(52, 52) }, club)
	local name = text({ Name = "ClubName", Position = UDim2.fromOffset(74, 10), Size = UDim2.fromOffset(CARD_SIZE.X - 84, 56), Text = club.name, TextSize = 18, TextWrapped = true, Parent = body })
	outline(name, 1.5)
	UiKit.stars(body, { Name = "Stars", Position = UDim2.fromOffset(12, 74) }, club.stars, 20)
	UiKit.chip(body, { Name = "Ovr", Position = UDim2.fromOffset(12, 104) }, string.format(TEXT.Ovr, club.ovr), LILAC)

	local lock = nil
	if not club.open then
		lock = frame({ Name = "Locked", Size = UDim2.fromScale(1, 1), BackgroundColor3 = INK, BackgroundTransparency = 0.42, ZIndex = 4, Parent = body })
		corner(lock, 12)
	end
	local tag = frame({
		Name = "Tag",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -10, 1, -10),
		Size = UDim2.fromOffset(0, 26),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = if club.open then LIME else NAVY,
		ZIndex = 6,
		Parent = body,
	})
	corner(tag, 7)
	stroke(tag, if club.open then INK else LILAC, 2)
	create("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), Parent = tag })
	local tagText = text({
		Size = UDim2.fromScale(0, 1),
		AutomaticSize = Enum.AutomaticSize.X,
		Text = if club.open then TEXT.ClubOpen else string.format(TEXT.ClubLocked, club.unlockOvr or 99),
		TextSize = 13,
		TextColor3 = if club.open then INK else LILAC,
		Parent = tag,
	})

	button.Activated:Connect(function()
		if club.open then
			self.selectedClub = club
			self:_refreshCards()
			UiKit.pop(pop, 0.92)
		else
			self.clubHint.Text = string.format(TEXT.ClubLockedHint, club.name, club.unlockOvr or 99)
			self.clubHint.TextColor3 = RED_LIGHT
			body.Rotation = 4
			TweenService:Create(body, TweenInfo.new(0.45, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out), { Rotation = 0 }):Play()
		end
	end)
	return { club = club, glows = glows, border = border, tag = tag, tagText = tagText }
end

function CareerMenu:_refreshCards()
	local selected = self.selectedClub
	for _, card in self.cards do
		local picked = card.club == selected
		for _, glow in card.glows do
			glow.Color = if picked then GOLD else GLOW
			glow.Enabled = card.club.open
		end
		card.border.Color = if picked then GOLD else VIOLET
		card.border.Thickness = if picked then 3 else 2
		if card.club.open then
			card.tagText.Text = if picked then TEXT.ClubPicked else TEXT.ClubOpen
			card.tag.BackgroundColor3 = if picked then GOLD else LIME
		end
	end
	self.clubNext:setEnabled(selected ~= nil)
	self.clubHint.TextColor3 = CREAM
	self.clubHint.Text = if selected then string.format(TEXT.ClubChosenHint, selected.name) else TEXT.ClubPickHint
	if selected then
		self.clubNext:playShine()
	end
end

---------------------------------------------------------------- player creation

function CareerMenu:_buildPlayer()
	local screen = self:_screen("PLAYER", SCREEN_SIZE)
	local c = screen.content

	-- Form
	local form = UiKit.panel({ Name = "Form", Size = UDim2.fromOffset(400, SCREEN_SIZE.Y), Parent = c }, 16)
	self.form = form
	UiKit.slashes(form, UDim2.new(1, -66, 0, 14), 22, GLOW)
	UiKit.bigText({ Name = "Title", Text = TEXT.PlayerTitle, TextSize = 30, Position = UDim2.fromOffset(20, 12), Size = UDim2.fromOffset(300, 38), Parent = form }, 3, Vector2.new(2, 3))
	self.formCrestHolder = frame({ Name = "Club", Position = UDim2.fromOffset(20, 56), Size = UDim2.fromOffset(360, 32), BackgroundTransparency = 1, Parent = form })

	local function label(y: number, value: string)
		local l = text({ Position = UDim2.fromOffset(20, y), Size = UDim2.fromOffset(360, 18), Text = value, TextSize = 14, FontFace = FONT_BOLD, TextColor3 = LILAC, Parent = form })
		outline(l, 1)
	end
	label(96, TEXT.FirstName)
	self.firstBox = UiKit.textBox(form, { Name = "FirstName", Position = UDim2.fromOffset(20, 116), Size = UDim2.fromOffset(360, 42) }, TEXT.FirstPlaceholder)
	label(166, TEXT.LastName)
	self.lastBox = UiKit.textBox(form, { Name = "LastName", Position = UDim2.fromOffset(20, 186), Size = UDim2.fromOffset(360, 42) }, TEXT.LastPlaceholder)
	label(236, TEXT.Number)

	UiKit.button(form, { Name = "Minus", Position = UDim2.fromOffset(20, 256), Size = UDim2.fromOffset(46, 46), TextSize = 26 }, "−", function()
		self:_setNumber(((self.number or CareerConfig.Number.Default) - 2) % CareerConfig.Number.Max + 1)
	end, "secondary")
	self.numberBox = UiKit.textBox(form, { Name = "Number", Position = UDim2.fromOffset(74, 256), Size = UDim2.fromOffset(78, 42), TextSize = 24, TextXAlignment = Enum.TextXAlignment.Center }, "10")
	UiKit.button(form, { Name = "Plus", Position = UDim2.fromOffset(160, 256), Size = UDim2.fromOffset(46, 46), TextSize = 26 }, "+", function()
		self:_setNumber((self.number or CareerConfig.Number.Default) % CareerConfig.Number.Max + 1)
	end, "secondary")

	self.picks = {}
	for i, value in CareerConfig.Number.Picks do
		local pick = create("TextButton", {
			Name = "Pick" .. value,
			Position = UDim2.fromOffset(20 + (i - 1) * 61, 310),
			Size = UDim2.fromOffset(52, 32),
			BackgroundColor3 = NAVY,
			AutoButtonColor = false,
			Text = tostring(value),
			TextSize = 17,
			FontFace = UiKit.FONT_HEAVY,
			TextColor3 = CREAM,
			BorderSizePixel = 0,
			Parent = form,
		})
		corner(pick, 8)
		self.picks[value] = stroke(pick, VIOLET, 2)
		pick.Activated:Connect(function()
			self:_setNumber(value)
		end)
	end

	self.formError = text({ Name = "Error", Position = UDim2.fromOffset(20, 348), Size = UDim2.fromOffset(360, 20), Text = "", TextSize = 14, FontFace = FONT_BOLD, TextColor3 = RED_LIGHT, TextWrapped = true, Parent = form })
	outline(self.formError, 1)

	UiKit.button(form, { Name = "Back", Position = UDim2.fromOffset(20, 376), Size = UDim2.fromOffset(124, 52) }, TEXT.Back, function()
		if not self.busy then
			self:_show("CLUBS")
		end
	end, "secondary")
	self.confirmButton = UiKit.button(form, { Name = "Confirm", Position = UDim2.fromOffset(156, 376), Size = UDim2.fromOffset(224, 52) }, TEXT.Confirm, function()
		self:_submit()
	end, "primary")

	self.firstBox:GetPropertyChangedSignal("Text"):Connect(function()
		limitLength(self.firstBox, CareerConfig.Name.MaxLength)
		self.formError.Text = ""
	end)
	self.lastBox:GetPropertyChangedSignal("Text"):Connect(function()
		limitLength(self.lastBox, CareerConfig.Name.MaxLength)
		self.formError.Text = ""
		self.preview:setIdentity(self.lastBox.Text, self.number)
	end)
	self.numberBox:GetPropertyChangedSignal("Text"):Connect(function()
		local digits = string.sub(string.gsub(self.numberBox.Text, "%D", ""), 1, 2)
		if digits ~= self.numberBox.Text then
			self.numberBox.Text = digits -- fires this handler again with the clean text
			return
		end
		local value = tonumber(digits)
		self.number = if value and CareerConfig.validNumber(value) then value else nil
		self:_refreshPicks()
		self.formError.Text = ""
		self.preview:setIdentity(self.lastBox.Text, self.number)
	end)
	self.firstBox.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			self.lastBox:CaptureFocus()
		end
	end)

	self:_buildSigned(c)
end

-- Same spot as the form: replaces it once the server has accepted the player.
function CareerMenu:_buildSigned(parent: Instance)
	local signed = UiKit.panel({ Name = "Signed", Size = UDim2.fromOffset(400, SCREEN_SIZE.Y), Visible = false, Parent = parent }, 16, GOLD)
	self.signed = signed
	self.signedPop = create("UIScale", { Parent = signed })
	UiKit.slashes(signed, UDim2.fromOffset(16, 12), 22, GLOW)
	UiKit.slashes(signed, UDim2.new(1, -66, 0, 12), 22, GLOW)
	local title = UiKit.bigText({ Name = "Title", Text = TEXT.SignedTitle, TextSize = 40, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(20, 34), Size = UDim2.fromOffset(360, 96), Parent = signed }, 4, Vector2.new(0, 4), 40)
	create("UIGradient", { Rotation = 90, Color = ColorSequence.new(CREAM, GOLD), Parent = title })
	self.signedCrestHolder = frame({ Name = "CrestHolder", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 140), Size = UDim2.fromOffset(64, 64), BackgroundTransparency = 1, Parent = signed })
	self.signedClub = text({ Name = "Club", Position = UDim2.fromOffset(20, 210), Size = UDim2.fromOffset(360, 28), Text = "", TextSize = 22, TextXAlignment = Enum.TextXAlignment.Center, Parent = signed })
	outline(self.signedClub, 2)
	self.signedPlayer = text({ Name = "Player", Position = UDim2.fromOffset(20, 240), Size = UDim2.fromOffset(360, 24), Text = "", TextSize = 18, FontFace = FONT_BOLD, TextXAlignment = Enum.TextXAlignment.Center, Parent = signed })
	outline(self.signedPlayer, 1.5)

	local chips = frame({ Name = "Chips", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 274), Size = UDim2.fromOffset(360, 28), BackgroundTransparency = 1, Parent = signed })
	create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder, Parent = chips })
	local _, ovr = UiKit.chip(chips, { LayoutOrder = 1 }, "", LIME)
	local _, level = UiKit.chip(chips, { LayoutOrder = 2 }, "", GOLD)
	self.signedOvr, self.signedLevel = ovr, level

	local info = text({ Name = "Info", Position = UDim2.fromOffset(24, 312), Size = UDim2.fromOffset(352, 44), Text = TEXT.SignedInfo, TextSize = 15, FontFace = FONT_MEDIUM, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, Parent = signed })
	outline(info, 1)
	self.trainingButton = UiKit.button(signed, { Name = "ToTraining", Position = UDim2.fromOffset(20, 376), Size = UDim2.fromOffset(360, 52) }, TEXT.ToTraining, function()
		self:_startTraining(self.trainingButton)
	end, "primary")
end

function CareerMenu:_setNumber(value: number)
	self.numberBox.Text = tostring(value) -- the Text handler updates the preview
end

function CareerMenu:_refreshPicks()
	for value, pickStroke in self.picks do
		local on = value == self.number
		pickStroke.Color = if on then GOLD else VIOLET
		pickStroke.Thickness = if on then 3 else 2
	end
end

function CareerMenu:_enterPlayer()
	local club = self.selectedClub
	for _, child in self.formCrestHolder:GetChildren() do
		child:Destroy()
	end
	UiKit.crest(self.formCrestHolder, { Size = UDim2.fromOffset(32, 32) }, club)
	local clubName = text({ Position = UDim2.fromOffset(42, 0), Size = UDim2.new(1, -42, 1, 0), Text = club.name, TextSize = 18, FontFace = FONT_BOLD, Parent = self.formCrestHolder })
	outline(clubName, 1.5)

	self.form.Visible = true
	self.signed.Visible = false
	self.formError.Text = ""
	self.confirmButton:setText(TEXT.Confirm)
	self.confirmButton:setEnabled(true)
	self:_show("PLAYER")
	self.preview:show(self.lastBox.Text, nil)
	if self.numberBox.Text == "" then
		self:_setNumber(CareerConfig.Number.Default)
	else
		self.preview:setIdentity(self.lastBox.Text, self.number, true)
	end
	self.confirmButton:playShine()
end

function CareerMenu:_submit()
	if self.busy then
		return
	end
	local _, firstError = CareerConfig.cleanName(self.firstBox.Text)
	local _, lastError = CareerConfig.cleanName(self.lastBox.Text)
	local problem = if firstError then "FIRST_" .. firstError elseif lastError then "LAST_" .. lastError elseif not self.number then "BAD_NUMBER" else nil
	if problem then
		self.formError.Text = errorText(problem)
		return
	end

	self.busy = true
	self.confirmButton:setText(TEXT.Saving)
	self.confirmButton:setEnabled(false)
	task.spawn(function()
		local result = self:_request("CREATE", {
			clubId = self.selectedClub.id,
			firstName = self.firstBox.Text,
			lastName = self.lastBox.Text,
			number = self.number,
			replace = self.replace,
		})
		self.busy = false
		self.confirmButton:setText(TEXT.Confirm)
		self.confirmButton:setEnabled(true)
		if not result.ok then
			self.formError.Text = errorText(result.error)
			return
		end
		self.career = result.career
		self.replace = false
		self:_refreshMain()
		self:_showSigned()
	end)
end

function CareerMenu:_showSigned()
	local career = self.career
	local club = CareerConfig.club(career.clubId)
	for _, child in self.signedCrestHolder:GetChildren() do
		child:Destroy()
	end
	UiKit.crest(self.signedCrestHolder, { Size = UDim2.fromOffset(64, 64) }, club)
	self.signedClub.Text = club.name
	self.signedPlayer.Text = string.format(TEXT.SignedPlayer, career.firstName, career.lastName, career.number)
	self.signedOvr.Text = string.format(TEXT.Ovr, career.ovr)
	self.signedLevel.Text = string.format(TEXT.Level, career.level)
	self.form.Visible = false
	self.signed.Visible = true
	UiKit.pop(self.signedPop, 0.6)
	self.trainingButton:setEnabled(true)
	self.trainingButton:playShine()
	-- The shirt shows the name exactly as the server saved it.
	self.preview:setIdentity(career.lastName, career.number, true)
	self.preview:celebrate()
end

function CareerMenu:_startTraining(button)
	if self.busy then
		return
	end
	self.busy = true
	button:setEnabled(false)
	task.spawn(function()
		local result = self:_request("START_TRAINING")
		self.busy = false
		button:setEnabled(true)
		if result.ok then
			self:close()
			if self.onStartTraining then
				self.onStartTraining(self.career)
			end
		elseif result.error == "TRAINING_DONE" then
			self.career.training = "DONE"
			self:_showNext(false)
		else
			self.status.Text = errorText(result.error)
			self:_show("MAIN")
		end
	end)
end

---------------------------------------------------------------- next match (after training)

function CareerMenu:_buildNextMatch()
	local screen = self:_screen("NEXT", SCREEN_SIZE)
	local body = UiKit.panel({ Name = "Card", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(540, 384), Parent = screen.content }, 16, GOLD)
	UiKit.slashes(body, UDim2.fromOffset(16, 12), 24, GLOW)
	UiKit.slashes(body, UDim2.new(1, -66, 0, 12), 24, GLOW)
	local title, titleShadow = UiKit.bigText({ Name = "Title", Text = TEXT.TrainedTitle, TextSize = 40, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(20, 22), Size = UDim2.new(1, -40, 0, 96), Parent = body }, 4, Vector2.new(0, 4), 40)
	create("UIGradient", { Rotation = 90, Color = ColorSequence.new(CREAM, GOLD), Parent = title })
	self.nextTitle = title
	self.nextTitleShadow = titleShadow
	self.nextPlayer = text({ Name = "Player", Position = UDim2.fromOffset(20, 124), Size = UDim2.new(1, -40, 0, 22), Text = "", TextSize = 16, FontFace = FONT_BOLD, TextXAlignment = Enum.TextXAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd, Parent = body })
	outline(self.nextPlayer, 1.5)

	local fixture = frame({ Name = "Fixture", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 156), Size = UDim2.fromOffset(480, 128), BackgroundColor3 = NAVY, Parent = body })
	corner(fixture, 12)
	stroke(fixture, VIOLET, 2)
	local heading = text({ Position = UDim2.fromOffset(0, 8), Size = UDim2.new(1, 0, 0, 20), Text = TEXT.FirstMatch, TextSize = 15, TextColor3 = GOLD, TextXAlignment = Enum.TextXAlignment.Center, Parent = fixture })
	outline(heading, 1.5)
	local versus = UiKit.bigText({ Name = "Vs", Text = "VS", TextSize = 34, TextColor3 = RED, TextXAlignment = Enum.TextXAlignment.Center, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 46), Size = UDim2.fromOffset(80, 40), Parent = fixture }, 3, Vector2.new(2, 3))
	versus.ZIndex = 2
	self.fixtureSides = {}
	for i, x in { 0.25, 0.75 } do
		local side = frame({ Name = "Side" .. i, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(x, 0, 0, 32), Size = UDim2.fromOffset(200, 90), BackgroundTransparency = 1, Parent = fixture })
		local crestHolder = frame({ Name = "CrestHolder", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0), Size = UDim2.fromOffset(56, 56), BackgroundTransparency = 1, Parent = side })
		local name = text({ Name = "ClubName", Position = UDim2.fromOffset(0, 62), Size = UDim2.new(1, 0, 0, 22), Text = "", TextSize = 16, TextXAlignment = Enum.TextXAlignment.Center, Parent = side })
		outline(name, 1.5)
		self.fixtureSides[i] = { crest = crestHolder, name = name }
	end

	self.nextStats = text({ Name = "Stats", Position = UDim2.fromOffset(20, 292), Size = UDim2.new(1, -40, 0, 20), Text = "", TextSize = 14, FontFace = FONT_BOLD, TextColor3 = LILAC, TextXAlignment = Enum.TextXAlignment.Center, Parent = body })
	outline(self.nextStats, 1)
	self.menuButton = UiKit.button(body, { Name = "ToMenu", Position = UDim2.fromOffset(30, 322), Size = UDim2.fromOffset(200, 52), TextSize = 18 }, TEXT.ToMenu, function()
		if not self.busy then
			self:_show("MAIN")
		end
	end, "secondary")
	self.matchButton = UiKit.button(body, { Name = "PlayMatch", Position = UDim2.fromOffset(242, 322), Size = UDim2.fromOffset(268, 52) }, TEXT.PlayMatch, function()
		self:_startMatch()
	end, "primary")
end

function CareerMenu:_startMatch()
	if self.busy or not self.career then
		return
	end
	self.busy = true
	self.matchButton:setEnabled(false)
	task.spawn(function()
		local result = self:_request("START_MATCH")
		self.busy = false
		self.matchButton:setEnabled(true)
		if result.ok and self.onStartMatch then
			self:close()
			self.onStartMatch(self.career, result.match)
		else
			self.nextStats.Text = errorText(result.error)
		end
	end)
end

-- The server's copy of the career after a match (level, goals, matches).
function CareerMenu:setCareer(career)
	self.career = career
end

function CareerMenu:_showNext(justTrained: boolean)
	local career = self.career
	local club = career and CareerConfig.club(career.clubId)
	if not (career and club) then
		self:_show("MAIN")
		return
	end
	local title = if justTrained then TEXT.TrainedTitle else TEXT.CareerTitle
	self.nextTitle.Text = title
	if self.nextTitleShadow then
		self.nextTitleShadow.Text = title
	end
	self.nextPlayer.Text = string.format(TEXT.CareerLine, career.firstName, career.lastName, career.number, club.name)
	for i, side in { club, CareerConfig.firstOpponent(club) } do
		local slot = self.fixtureSides[i]
		for _, child in slot.crest:GetChildren() do
			child:Destroy()
		end
		UiKit.crest(slot.crest, { Size = UDim2.fromOffset(56, 56) }, side)
		slot.name.Text = side.name
	end
	self.nextStats.Text = string.format(TEXT.CareerStats, career.level or 1, career.matches or 0, career.goals or 0, career.assists or 0)
	self:_show("NEXT")
	self.matchButton:setEnabled(true)
	self.matchButton:playShine()
end

---------------------------------------------------------------- settings and confirmations

function CareerMenu:_buildOverlay()
	local overlay = frame({ Name = "Overlay", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, ZIndex = 30, Parent = self.gui })
	self.overlay = overlay
	self.overlayDim = frame({ Name = "Dim", Position = UDim2.fromOffset(-200, -120), Size = UDim2.new(1, 400, 1, 240), BackgroundColor3 = INK, BackgroundTransparency = 0.45, Parent = overlay })

	local function modal(name: string, size: Vector2)
		local holder = frame({ Name = name, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(size.X, size.Y), BackgroundTransparency = 1, Visible = false, Parent = overlay })
		self.scaler:add(holder)
		local body = UiKit.panel({ Name = "Body", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), Parent = holder }, 16)
		return holder, body, create("UIScale", { Parent = body })
	end

	-- Settings
	local settings, sBody, sPop = modal("Settings", Vector2.new(460, 330))
	self.settingsModal, self.settingsPop = settings, sPop
	UiKit.bigText({ Name = "Title", Text = TEXT.SettingsTitle, TextSize = 32, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(20, 16), Size = UDim2.new(1, -40, 0, 40), Parent = sBody }, 3, Vector2.new(2, 3))
	local function row(y: number, label: string, key: string)
		local l = text({ Position = UDim2.fromOffset(24, y), Size = UDim2.fromOffset(300, 34), Text = label, TextSize = 17, FontFace = FONT_BOLD, Parent = sBody })
		outline(l, 1.5)
		return UiKit.toggle(sBody, { Name = key, Position = UDim2.new(1, -100, 0, y) }, self.settings[key], function(value)
			self:_changeSetting(key, value)
		end)
	end
	self.toggles = { shake = row(80, TEXT.Shake, "shake"), bigUi = row(128, TEXT.BigUi, "bigUi") }
	self.deleteButton = UiKit.button(sBody, { Name = "Delete", Position = UDim2.fromOffset(24, 188), Size = UDim2.fromOffset(412, 48) }, TEXT.DeleteCareer, function()
		self:_askDelete()
	end, "danger")
	self.deleteButton.button.Visible = false
	UiKit.button(sBody, { Name = "Done", Position = UDim2.fromOffset(24, 260), Size = UDim2.fromOffset(412, 52) }, TEXT.Done, function()
		self:_closeOverlay()
	end, "primary")

	-- Yes / no
	local confirm, cBody, cPop = modal("Confirm", Vector2.new(480, 256))
	self.confirmModal, self.confirmPop = confirm, cPop
	self.confirmTitle, self.confirmTitleShadow = UiKit.bigText({ Name = "Title", Text = "", TextSize = 30, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(20, 18), Size = UDim2.new(1, -40, 0, 38), Parent = cBody }, 3, Vector2.new(2, 3))
	self.confirmBody = text({ Name = "Body", Position = UDim2.fromOffset(24, 70), Size = UDim2.new(1, -48, 0, 90), Text = "", TextSize = 17, FontFace = FONT_MEDIUM, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, Parent = cBody })
	outline(self.confirmBody, 1)
	UiKit.button(cBody, { Name = "Cancel", Position = UDim2.fromOffset(24, 184), Size = UDim2.fromOffset(204, 52) }, TEXT.Cancel, function()
		self:_closeOverlay()
	end, "secondary")
	local function yes()
		local action = self.confirmAction
		self:_closeOverlay()
		if action then
			action()
		end
	end
	self.confirmYes = UiKit.button(cBody, { Name = "Yes", Position = UDim2.fromOffset(252, 184), Size = UDim2.fromOffset(204, 52) }, "", yes, "primary")
	self.confirmDanger = UiKit.button(cBody, { Name = "YesDanger", Position = UDim2.fromOffset(252, 184), Size = UDim2.fromOffset(204, 52) }, "", yes, "danger")
end

function CareerMenu:_openOverlay(modal: Frame, pop: UIScale)
	self.overlay.Visible = true
	self.settingsModal.Visible = modal == self.settingsModal
	self.confirmModal.Visible = modal == self.confirmModal
	UiKit.pop(pop, 0.6)
end

function CareerMenu:_closeOverlay()
	self.overlay.Visible = false
	self.confirmAction = nil
end

function CareerMenu:_openSettings()
	for key, toggle in self.toggles do
		toggle:set(self.settings[key])
	end
	self.deleteButton.button.Visible = self.career ~= nil
	self:_openOverlay(self.settingsModal, self.settingsPop)
end

function CareerMenu:_confirm(title: string, body: string, yesText: string, danger: boolean, action: () -> ())
	self.confirmTitle.Text = title
	if self.confirmTitleShadow then
		self.confirmTitleShadow.Text = title
	end
	self.confirmBody.Text = body
	self.confirmYes.button.Visible = not danger
	self.confirmDanger.button.Visible = danger
	local button = if danger then self.confirmDanger else self.confirmYes
	button:setText(yesText)
	self.confirmAction = action
	self:_openOverlay(self.confirmModal, self.confirmPop)
end

function CareerMenu:_askDelete()
	local club = self.career and CareerConfig.club(self.career.clubId)
	if not club then
		return
	end
	self:_confirm(TEXT.DeleteTitle, string.format(TEXT.DeleteBody, club.name), TEXT.DeleteYes, true, function()
		task.spawn(function()
			local result = self:_request("DELETE")
			if result.ok then
				self.career = nil
			else
				self.status.Text = errorText(result.error)
			end
			self:_refreshMain()
		end)
	end)
end

function CareerMenu:_applySettings(settings)
	self.settings = { shake = settings.shake ~= false, bigUi = settings.bigUi == true }
	self.scaler:setBoost(if self.settings.bigUi then 1.15 else 1)
	if self.onSettingsChanged then
		self.onSettingsChanged(self.settings)
	end
end

function CareerMenu:_changeSetting(key: string, value: boolean)
	local settings = table.clone(self.settings)
	settings[key] = value
	self:_applySettings(settings)
	-- Applied at once, saved once the toggling stops (the server rate-limits requests).
	self.settingsToken = (self.settingsToken or 0) + 1
	local token = self.settingsToken
	task.delay(0.6, function()
		if token ~= self.settingsToken then
			return
		end
		local result = self:_request("SETTINGS", self.settings)
		if not result.ok then
			warn("[CareerMenu] settings not saved:", result.error)
		end
	end)
end

---------------------------------------------------------------- screens, camera, open / close

function CareerMenu:_show(name: string)
	for key, screen in self.screens do
		screen.root.Visible = key == name
	end
	local screen = self.screens[name]
	UiKit.pop(screen.pop, 0.94)
	self.current = name
	self.cameraMode = if name == "MAIN" then "MENU" elseif name == "PLAYER" then "CREATE" elseif name == "CLUBS" then "CLUBS" else "NEXT"
	self.shade.Visible = name ~= "NEXT"
	if name ~= "PLAYER" then
		self.preview:hide()
	end
	if name == "MAIN" then
		self:_refreshMain()
	end
end

-- Back from the training. justTrained: the pass task was just completed.
function CareerMenu:open(justTrained: boolean?)
	self.active = true
	self.gui.Enabled = true
	self.blur.Enabled = true
	self.depth.Enabled = true
	self.camCFrame = workspace.CurrentCamera.CFrame -- glide from wherever the training left it
	self.camFov = workspace.CurrentCamera.FieldOfView
	if justTrained and self.career then
		self.career.training = "DONE" -- the server marked it when the task was completed
		self:_showNext(true)
	else
		self:_show("MAIN")
	end
	task.spawn(function()
		local result = self:_request("GET")
		if result.ok then
			self.career = result.career
			if self.current == "MAIN" then
				self:_refreshMain()
			end
		end
	end)
end

function CareerMenu:close()
	self.active = false
	self.gui.Enabled = false
	self.blur.Enabled = false
	self.depth.Enabled = false
	self.overlay.Visible = false
	self.preview:hide()
end

function CareerMenu:isOpen(): boolean
	return self.active
end

-- Per-frame while open: camera glide between framings, blur / depth of field and the player.
function CareerMenu:update(dt: number)
	if not self.active then
		return
	end
	self.clock += dt
	self.preview:update(dt)

	local mode = self.cameraMode
	local t = self.clock
	local target, fov, focus
	if mode == "CREATE" then
		target, fov, focus = PlayerPreview.cameraTarget(mode)
	else
		local framing = if mode == "MENU" then MENU_CAMERA else CLUBS_CAMERA
		local sway = Vector3.new(math.sin(t * 0.13) * 6, math.sin(t * 0.09) * 1.2, 0)
		target, fov = CFrame.lookAt(framing.from + sway, framing.to), framing.fov
	end
	local k = 1 - math.exp(-3 * dt)
	self.camCFrame = self.camCFrame:Lerp(target, k)
	self.camFov += (fov - self.camFov) * k
	local camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = self.camCFrame
	camera.FieldOfView = self.camFov
	self.blur.Size += ((BLUR[mode] or 0) - self.blur.Size) * k
	self.depth.Enabled = DEPTH[mode] == true
	if focus then
		self.depth.FocusDistance = focus
	end
end

return CareerMenu
