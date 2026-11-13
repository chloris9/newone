-- Trial commentator and the match screen's texts, in Russian and English. The language is picked
-- automatically: the account's Roblox language first, then the country the player is in.
-- Every key has a few variants so matches don't read the same; placeholders:
--   {home} {away} our club and the opponent, {me} the player's surname, {n} a teammate's number,
--   {h} {a} the score.
-- Voice: put an uploaded sound id per key into Commentary.Voice[language] to have the line
-- spoken as well (empty = text only).

local LocalizationService = game:GetService("LocalizationService")
local Players = game:GetService("Players")

local Commentary = {}

-- Countries where the game speaks Russian when the account language isn't Russian itself.
local RUSSIAN_COUNTRIES = { RU = true, BY = true, KZ = true, KG = true }

local LINES = {
	RU = {
		KICKOFF = { "Свисток! {home} против {away} — матч начался!", "Поехали! {home} принимает {away}." },
		HALFTIME = { "Перерыв. На табло {h}:{a}.", "Первый тайм позади — {h}:{a}." },
		FULLTIME_WIN = { "Финальный свисток! {home} побеждает — {h}:{a}!", "Всё! Победа {home}, {h}:{a}!" },
		FULLTIME_DRAW = { "Финальный свисток. Ничья — {h}:{a}.", "Матч окончен, победителя нет: {h}:{a}." },
		FULLTIME_LOSS = { "Финальный свисток. {away} увозит победу — {h}:{a}.", "Всё кончено: {h}:{a} в пользу {away}." },
		OPP_GOAL = { "ГОЛ… {away} забивает. {h}:{a}.", "Пропустили! {away} реализует момент — {h}:{a}." },
		OPP_SAVE = { "Опасно у наших ворот — вратарь тащит!", "{away} бьёт в створ, но наш кипер на месте!" },
		OPP_MISS = { "{away} атакует… мимо ворот.", "Удар у {away} — выше перекладины." },
		TEAM_GOAL = { "ГОЛ! Номер {n} забивает за {home}! {h}:{a}!", "{home} забивает! Отличился номер {n} — {h}:{a}!" },
		TEAM_MISS = { "Номер {n} бьёт — рядом со штангой.", "Момент у {home}! Номер {n} не попал в створ." },
		MOMENT_CHOICE = { "Мяч у {me}! Бить самому или отдать партнёру?", "{me} с мячом перед штрафной — решай!" },
		MOMENT_RECEIVE = { "Номер {n} находит {me} — шанс для удара!", "Передача от номера {n}… {me} может бить!" },
		YOU_GOAL = { "ГОООЛ! {me} забивает! {h}:{a}!", "Какой удар! {me} — и мяч в сетке! {h}:{a}!" },
		YOU_SAVE = { "{me} бьёт — вратарь спасает!", "Удар {me}… сейв!" },
		YOU_POST = { "{me} бьёт — каркас ворот! Сантиметры…", "Штанга спасает {away} после удара {me}!" },
		YOU_MISS = { "{me} бьёт — мимо.", "Удар {me} — неточно." },
		PASS_GOOD = { "Отличный пас от {me}!", "{me} находит партнёра — передача прошла!" },
		PASS_FAIL = { "Пас {me} перехвачен — атака захлебнулась.", "Передача {me} не дошла до адресата." },
		ASSIST_GOAL = { "ГОЛ! Номер {n} замыкает передачу {me}! {h}:{a}!", "Голевой пас {me}! Номер {n} забивает — {h}:{a}!" },
		MATE_SAVE = { "Номер {n} бьёт после паса {me} — вратарь отбивает!", "Сейв! Номер {n} не смог переиграть кипера." },
		MATE_MISS = { "Номер {n} бьёт после паса {me} — мимо.", "Хорошая передача {me}, но номер {n} не попал." },
	},
	EN = {
		KICKOFF = { "Kick-off! {home} against {away} — we're under way!", "Here we go! {home} host {away}." },
		HALFTIME = { "Half-time. It's {h}-{a}.", "That's the first half done — {h}-{a}." },
		FULLTIME_WIN = { "Full time! {home} win it, {h}-{a}!", "It's all over! Victory for {home}, {h}-{a}!" },
		FULLTIME_DRAW = { "Full time. Honours even — {h}-{a}.", "The final whistle, and nothing to separate them: {h}-{a}." },
		FULLTIME_LOSS = { "Full time. {away} take the points — {h}-{a}.", "It's over: {h}-{a} to {away}." },
		OPP_GOAL = { "GOAL… {away} score. {h}-{a}.", "They've conceded! {away} take their chance — {h}-{a}." },
		OPP_SAVE = { "Danger at our end — the keeper saves!", "{away} get a shot on target, but our keeper is there!" },
		OPP_MISS = { "{away} attack… wide of the goal.", "A shot from {away} — over the bar." },
		TEAM_GOAL = { "GOAL! Number {n} scores for {home}! {h}-{a}!", "{home} score! Number {n} with the finish — {h}-{a}!" },
		TEAM_MISS = { "Number {n} shoots — just past the post.", "A chance for {home}! Number {n} can't hit the target." },
		MOMENT_CHOICE = { "{me} has the ball! Shoot, or find a teammate?", "{me} on the ball outside the box — your call!" },
		MOMENT_RECEIVE = { "Number {n} finds {me} — a chance to shoot!", "A pass from number {n}… {me} can hit this!" },
		YOU_GOAL = { "GOOOAL! {me} scores! {h}-{a}!", "What a strike! {me} — and it's in the net! {h}-{a}!" },
		YOU_SAVE = { "{me} shoots — saved by the keeper!", "A shot from {me}… great save!" },
		YOU_POST = { "{me} shoots — off the woodwork! Inches away…", "The frame of the goal saves {away} from {me}!" },
		YOU_MISS = { "{me} shoots — off target.", "A shot from {me} — it's wide." },
		PASS_GOOD = { "Lovely pass from {me}!", "{me} picks out a teammate — that's through!" },
		PASS_FAIL = { "{me}'s pass is cut out — the attack breaks down.", "The pass from {me} doesn't reach its man." },
		ASSIST_GOAL = { "GOAL! Number {n} finishes {me}'s pass! {h}-{a}!", "An assist for {me}! Number {n} scores — {h}-{a}!" },
		MATE_SAVE = { "Number {n} shoots from {me}'s pass — the keeper parries!", "Saved! Number {n} couldn't beat the keeper." },
		MATE_MISS = { "Number {n} shoots from {me}'s pass — wide.", "A fine ball from {me}, but number {n} misses the target." },
	},
}

-- Match screen labels.
local UI = {
	RU = {
		Shoot = "УДАР",
		Pass = "ПАС",
		Moment = "МОМЕНТ %d ИЗ %d",
		YourMoment = "ТВОЙ МОМЕНТ!",
		Commentator = "КОММЕНТАТОР",
		Win = "ПОБЕДА!",
		Draw = "НИЧЬЯ",
		Loss = "ПОРАЖЕНИЕ",
		Goals = "ГОЛЫ",
		Assists = "ПЕРЕДАЧИ",
		Rating = "ОЦЕНКА",
		Xp = "+%d XP",
		Level = "УРОВЕНЬ %d",
		Shots = "Удары: %d  ·  Точные пасы: %d из %d",
		Continue = "ПРОДОЛЖИТЬ  ›",
	},
	EN = {
		Shoot = "SHOOT",
		Pass = "PASS",
		Moment = "MOMENT %d OF %d",
		YourMoment = "YOUR MOMENT!",
		Commentator = "COMMENTATOR",
		Win = "VICTORY!",
		Draw = "DRAW",
		Loss = "DEFEAT",
		Goals = "GOALS",
		Assists = "ASSISTS",
		Rating = "RATING",
		Xp = "+%d XP",
		Level = "LEVEL %d",
		Shots = "Shots: %d  ·  Good passes: %d of %d",
		Continue = "CONTINUE  ›",
	},
}

-- Optional voice-over: Commentary.Voice.RU.YOU_GOAL = "rbxassetid://..." and so on.
Commentary.Voice = { RU = {}, EN = {} }

local detected: string? = nil

-- "RU" or "EN". Account language first ("ru-ru"), then the player's country.
function Commentary.language(): string
	if detected then
		return detected
	end
	local language
	local locale = string.lower(LocalizationService.RobloxLocaleId or "")
	if string.sub(locale, 1, 2) == "ru" then
		language = "RU"
	elseif locale ~= "" and string.sub(locale, 1, 2) ~= "en" then
		language = "EN" -- another language: English is the closest we have
	else
		local ok, country = pcall(function()
			return LocalizationService:GetCountryRegionForPlayerAsync(Players.LocalPlayer)
		end)
		language = if ok and RUSSIAN_COUNTRIES[country] then "RU" else "EN"
	end
	detected = language
	return language
end

function Commentary.ui()
	return UI[Commentary.language()]
end

-- A random variant of the line with its placeholders filled in.
function Commentary.line(key: string, params: { [string]: any }): string
	local variants = LINES[Commentary.language()][key]
	if not variants then
		return ""
	end
	local text = variants[math.random(1, #variants)]
	return (string.gsub(text, "{(%w+)}", function(name)
		local value = params[name]
		return if value ~= nil then tostring(value) else ""
	end))
end

-- Sound id for the line if a voice file was added, otherwise nil.
function Commentary.voice(key: string): string?
	return Commentary.Voice[Commentary.language()][key]
end

return Commentary
