-- Commentator and the match screen's texts, in Russian and English. The language is picked
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
		-- Whistles
		KICKOFF = { "Свисток! {home} против {away} — матч начался!", "Поехали! {home} принимает {away}.", "Мяч в игре! {home} и {away} начинают." },
		HALFTIME = { "Перерыв. На табло {h}:{a}.", "Первый тайм позади — {h}:{a}. Можно перевести дух.", "Команды уходят в раздевалку при счёте {h}:{a}." },
		LATE = { "Последние минуты! Всё решается сейчас.", "Время на исходе — {h}:{a} на табло.", "Арбитр уже поглядывает на часы…" },
		FULLTIME_WIN = { "Финальный свисток! {home} побеждает — {h}:{a}!", "Всё! Победа {home}, {h}:{a}!", "Конец матча! Три очка у {home} — {h}:{a}!" },
		FULLTIME_DRAW = { "Финальный свисток. Ничья — {h}:{a}.", "Матч окончен, победителя нет: {h}:{a}.", "Очки поделены: {h}:{a}." },
		FULLTIME_LOSS = { "Финальный свисток. {away} увозит победу — {h}:{a}.", "Всё кончено: {h}:{a} в пользу {away}.", "Сегодня не наш день: {h}:{a}." },
		-- Chances
		OPP_ATTACK = { "{away} быстро переходит в атаку…", "Опасный проход {away} по флангу!", "{away} навешивает в нашу штрафную…", "Контратака {away}! Трое против двоих…" },
		OPP_GOAL = { "ГОЛ… {away} забивает. {h}:{a}.", "Пропустили! {away} реализует момент — {h}:{a}.", "Мяч в наших воротах. {h}:{a}." },
		OPP_SAVE = { "Вратарь тащит! Какая реакция!", "Удар в створ — но наш кипер на месте!", "Сейв! Вратарь переводит на угловой." },
		OPP_MISS = { "Удар… мимо ворот.", "Выше перекладины! Выдыхаем.", "Защитник в последний момент выносит мяч!" },
		TEAM_ATTACK = { "{home} разыгрывает мяч у штрафной…", "Номер {n} врывается в штрафную!", "Быстрая атака {home} через центр!" },
		TEAM_GOAL = { "ГОЛ! Номер {n} забивает за {home}! {h}:{a}!", "{home} забивает! Отличился номер {n} — {h}:{a}!", "Номер {n} — и мяч в сетке! {h}:{a}!" },
		TEAM_MISS = { "Номер {n} бьёт — рядом со штангой.", "Не попал! Номер {n} хватается за голову.", "Вратарь {away} забирает удар номера {n}." },
		-- General play
		BUILDUP_US = { "{home} спокойно катает мяч в центре поля.", "Наши защитники разыгрывают мяч, ищут продольную передачу.", "{home} контролирует мяч, соперник отошёл назад." },
		BUILDUP_THEM = { "{away} владеет мячом и не торопится.", "Соперник перекатывает мяч от фланга к флангу.", "{away} пытается найти щель в нашей обороне." },
		MIDFIELD = { "Борьба в центре поля, мяч переходит из ног в ноги.", "Много единоборств — никто не хочет уступать.", "Игра идёт на встречных курсах." },
		FOUL_US = { "Фол на номере {n}! Штрафной для {home}.", "Нашего игрока сбивают — свисток арбитра.", "Грубо! Номер {n} лежит на газоне, но поднимается." },
		FOUL_THEM = { "Наш фол в центре поля, штрафной для {away}.", "Арбитр свистит: нарушение правил со стороны {home}.", "Подкат сзади — штрафной у наших ворот." },
		CORNER_US = { "Угловой для {home}! Высокие игроки идут вперёд.", "Подача с углового… защитник выбивает.", "Угловой — мяч пролетает через всю штрафную." },
		CORNER_THEM = { "Угловой у наших ворот, будьте внимательны!", "Подача {away} с углового — вратарь забирает.", "{away} разыгрывает угловой коротко." },
		OFFSIDE_US = { "Флажок поднят — номер {n} в офсайде.", "Офсайд! Атака {home} остановлена.", "Чуть раньше рванул — вне игры." },
		OFFSIDE_THEM = { "Офсайд у {away}! Наши защитники сработали чётко.", "Ловушка сработала — соперник вне игры.", "Флажок! Атака {away} прервана." },
		CROWD = { "Трибуны поют! Атмосфера просто огонь.", "Болельщики {home} требуют гола!", "Стадион гудит — слышно на весь город." },
		KEEPER_US = { "Наш вратарь выбивает мяч далеко вперёд.", "Кипер {home} начинает атаку длинным пасом.", "Вратарь не спешит, тянет время." },
		YELLOW_THEM = { "Жёлтая карточка игроку {away}!", "Предупреждение сопернику за срыв атаки.", "Арбитр достаёт жёлтую — {away} играет на грани." },
		YELLOW_US = { "Жёлтая карточка нашему игроку. Аккуратнее!", "Предупреждение для {home} за грубый подкат.", "Карточка — номер {n} в зоне риска." },
		SUB_THEM = { "{away} проводит замену — свежие ноги.", "У соперника замена в атаке.", "Тренер {away} что-то меняет." },
		-- You off the ball
		ME_RUN = { "{me} делает рывок за спину защитникам!", "{me} открывается, требует мяч!", "{me} постоянно в движении — защита нервничает." },
		ME_CALL = { "{me} показывает номеру {n}: «Давай сюда!»", "{me} ищет пространство между линиями.", "{me} смещается в полузону — там свободно." },
		TEAM_PRESS = { "{home} прессингует высоко!", "Наши давят — {away} не может выйти из обороны.", "Высокий прессинг {home} приносит плоды." },
		ME_TRACK = { "{me} возвращается помогать защите.", "{me} закрывает фланг — тренер доволен.", "{me} без устали работает в отборе." },
		TEAM_DEEP = { "{home} отошли в глубокую оборону.", "Наши играют от обороны и ждут шанса.", "Компактная оборона {home} — не пройти." },
		ME_TACKLE = { "{me} отбирает мяч! Отличный подкат!", "Перехват от {me} — атака соперника сорвана!", "{me} выигрывает единоборство в центре поля!" },
		ME_TIRED = { "{me} заметно подустал…", "{me} тяжело дышит — силы на исходе.", "Видно, что {me} отдал много сил." },
		ME_EXHAUSTED = { "{me} еле передвигает ноги! Выносливость почти на нуле.", "{me} выжат как лимон…", "У {me} совсем не осталось сил." },
		-- Your moments
		MOMENT_RECEIVE = { "Номер {n} находит {me}! Мяч у тебя!", "Передача от номера {n}… {me} принимает!", "Номер {n} отдаёт на {me} — твой момент!" },
		MOMENT_ONBALL = { "{me} с мячом далеко от штрафной!", "{me} выигрывает мяч и поднимает голову…", "Мяч у {me} — защитники уже бегут!" },
		YOU_GOAL = { "ГОООЛ! {me} забивает! {h}:{a}!", "Какой удар! {me} — и мяч в сетке! {h}:{a}!", "{me} кладёт мяч в девятку! {h}:{a}!" },
		YOU_SAVE = { "{me} бьёт — вратарь спасает!", "Удар {me}… сейв!", "Издалека {me} — кипер на месте." },
		YOU_POST = { "{me} бьёт — каркас ворот! Сантиметры…", "Штанга спасает {away} после удара {me}!", "Перекладина! {me} был так близко!" },
		YOU_MISS = { "{me} бьёт — мимо.", "Удар {me} — неточно.", "Издалека не получилось — {me} промахивается." },
		YOU_TACKLED = { "Отбор! {me} передержал мяч.", "Защитник {away} успевает — мяч потерян.", "{me} слишком долго думал — подкат!" },
		PASS_GOOD = { "Отличный пас от {me}!", "{me} находит номер {n} — передача прошла!", "Пас-разрез от {me}! Номер {n} с мячом!" },
		CROSS_GOOD = { "Навес от {me}… номер {n} в воздухе!", "Отличная подача {me} — номер {n} на мяче!", "{me} кидает верхом — номер {n} выпрыгивает!" },
		PASS_FAIL = { "Пас {me} перехвачен — атака захлебнулась.", "Передача {me} не дошла — защитник на месте.", "Перехват! {away} читает пас {me}." },
		CROSS_CLEARED = { "Навес {me} — защитник выбивает головой.", "Подача {me}… защита {away} сыграла на опережение.", "Верховой мяч от {me} — оборона справилась." },
		PASS_MISS = { "Передача {me} неточная — мяч уходит.", "{me} не попал в партнёра.", "Пас {me} в пустоту." },
		ASSIST_GOAL = { "ГОЛ! Номер {n} замыкает передачу {me}! {h}:{a}!", "Голевой пас {me}! Номер {n} забивает — {h}:{a}!", "Ассист {me}! Номер {n} без шансов для вратаря — {h}:{a}!" },
		HEADER_GOAL = { "ГОЛ ГОЛОВОЙ! Номер {n} после навеса {me}! {h}:{a}!", "Подача {me} — удар головой — ГОЛ! {h}:{a}!", "Номер {n} головой в угол! Ассист {me}! {h}:{a}!" },
		MATE_SAVE = { "Номер {n} бьёт после паса {me} — вратарь отбивает!", "Сейв! Номер {n} не смог переиграть кипера.", "Номер {n} бьёт… вратарь {away} начеку." },
		MATE_MISS = { "Номер {n} бьёт после паса {me} — мимо.", "Хорошая передача {me}, но номер {n} не попал.", "Номер {n} смазал удар после паса {me}." },
		HEADER_SAVE = { "Удар головой номера {n} — вратарь ловит!", "Номер {n} головой… сейв!", "Навес {me}, удар головой — кипер на месте." },
		HEADER_MISS = { "Номер {n} головой — выше ворот.", "Удар головой номера {n} мимо.", "Навес {me}, но номер {n} не попал головой." },
		-- Tactics (said when the player changes them)
		TACTIC_EFFORT_1 = { "{me} экономит силы.", "{me} сбавляет обороты." },
		TACTIC_EFFORT_2 = { "{me} играет в ровном темпе.", "{me} держит обычный ритм." },
		TACTIC_EFFORT_3 = { "{me} выкладывается на полную!", "{me} носится по всему полю!" },
		TACTIC_ATTACK = { "{me} подключается к атакам.", "{me} смещается ближе к воротам {away}." },
		TACTIC_DEFENSE = { "{me} помогает обороне.", "{me} играет от защиты." },
		STAMINA_EMPTY = { "{me} выдохся — на максимум сил больше нет.", "Силы кончились — {me} может только трусцой." },
	},
	EN = {
		KICKOFF = { "Kick-off! {home} against {away} — we're under way!", "Here we go! {home} host {away}.", "The ball is rolling! {home} and {away} get started." },
		HALFTIME = { "Half-time. It's {h}-{a}.", "That's the first half done — {h}-{a}. Time to catch a breath.", "The teams head in at {h}-{a}." },
		LATE = { "The final minutes! It all comes down to this.", "Time is running out — {h}-{a} on the board.", "The referee is checking his watch…" },
		FULLTIME_WIN = { "Full time! {home} win it, {h}-{a}!", "It's all over! Victory for {home}, {h}-{a}!", "That's it! Three points for {home} — {h}-{a}!" },
		FULLTIME_DRAW = { "Full time. Honours even — {h}-{a}.", "The final whistle, and nothing to separate them: {h}-{a}.", "Points shared: {h}-{a}." },
		FULLTIME_LOSS = { "Full time. {away} take the points — {h}-{a}.", "It's over: {h}-{a} to {away}.", "Not our day: {h}-{a}." },
		OPP_ATTACK = { "{away} break forward quickly…", "Dangerous run from {away} down the wing!", "{away} swing a ball into our box…", "Counter-attack for {away}! Three on two…" },
		OPP_GOAL = { "GOAL… {away} score. {h}-{a}.", "They've conceded! {away} take their chance — {h}-{a}.", "It's in our net. {h}-{a}." },
		OPP_SAVE = { "The keeper saves! What reflexes!", "On target — but our keeper is there!", "Save! Tipped round for a corner." },
		OPP_MISS = { "The shot… wide of the goal.", "Over the bar! We can breathe again.", "A last-ditch clearance from the defender!" },
		TEAM_ATTACK = { "{home} work it around the edge of the box…", "Number {n} bursts into the box!", "Quick attack from {home} through the middle!" },
		TEAM_GOAL = { "GOAL! Number {n} scores for {home}! {h}-{a}!", "{home} score! Number {n} with the finish — {h}-{a}!", "Number {n} — and it's in! {h}-{a}!" },
		TEAM_MISS = { "Number {n} shoots — just past the post.", "Missed! Number {n} can't believe it.", "The {away} keeper gathers number {n}'s shot." },
		BUILDUP_US = { "{home} knock it about calmly in midfield.", "Our defenders play it around, looking for the long ball.", "{home} in control, the opposition sitting deep." },
		BUILDUP_THEM = { "{away} have the ball and take their time.", "They move it from flank to flank.", "{away} probing for a gap in our defence." },
		MIDFIELD = { "A battle in midfield, the ball changing hands.", "Lots of duels — nobody giving an inch.", "End-to-end stuff now." },
		FOUL_US = { "Foul on number {n}! Free kick to {home}.", "Our man is brought down — the whistle goes.", "Ouch! Number {n} is down, but he's back up." },
		FOUL_THEM = { "Our foul in midfield, free kick to {away}.", "The referee blows: foul by {home}.", "A tackle from behind — free kick near our goal." },
		CORNER_US = { "Corner to {home}! The big men go forward.", "In comes the corner… headed clear.", "The corner flies right across the box." },
		CORNER_THEM = { "Corner at our end, stay switched on!", "{away} swing in the corner — the keeper claims it.", "{away} take the corner short." },
		OFFSIDE_US = { "The flag is up — number {n} is offside.", "Offside! {home}'s attack is stopped.", "Went a fraction too early — offside." },
		OFFSIDE_THEM = { "Offside against {away}! Our back line got that right.", "The trap works — they're offside.", "Flag! {away}'s attack comes to nothing." },
		CROWD = { "The stands are singing! What an atmosphere.", "The {home} fans want a goal!", "The stadium is rocking — you can hear it across town." },
		KEEPER_US = { "Our keeper launches it long.", "The {home} keeper starts the attack with a long ball.", "The keeper takes his time over that one." },
		YELLOW_THEM = { "Yellow card for {away}!", "A booking for stopping the attack.", "Out comes the yellow — {away} living dangerously." },
		YELLOW_US = { "A yellow card for one of ours. Careful now!", "Booking for {home} after a heavy tackle.", "Yellow — number {n} has to be careful." },
		SUB_THEM = { "{away} make a change — fresh legs.", "An attacking substitution for the opposition.", "The {away} coach is shaking things up." },
		ME_RUN = { "{me} darts in behind the defence!", "{me} finds space and calls for it!", "{me} never stops moving — the defence are nervous." },
		ME_CALL = { "{me} points to number {n}: \"Here!\"", "{me} drifts between the lines.", "{me} moves into the half-space — it's wide open." },
		TEAM_PRESS = { "{home} are pressing high!", "We're squeezing them — {away} can't get out.", "The high press from {home} is paying off." },
		ME_TRACK = { "{me} tracks back to help the defence.", "{me} covers the flank — the coach will like that.", "{me} working tirelessly without the ball." },
		TEAM_DEEP = { "{home} sit in a deep block.", "We defend first and wait for our chance.", "A compact {home} defence — no way through." },
		ME_TACKLE = { "{me} wins it back! Great tackle!", "Interception from {me} — their attack is over!", "{me} wins the duel in midfield!" },
		ME_TIRED = { "{me} is starting to tire…", "{me} is breathing hard — the legs are going.", "You can see {me} has given a lot." },
		ME_EXHAUSTED = { "{me} can barely run! Stamina almost gone.", "{me} is running on empty…", "{me} has nothing left in the tank." },
		MOMENT_RECEIVE = { "Number {n} finds {me}! Your ball!", "A pass from number {n}… {me} takes it!", "Number {n} plays it to {me} — your moment!" },
		MOMENT_ONBALL = { "{me} on the ball, well outside the box!", "{me} wins it and looks up…", "{me} has it — the defenders are coming!" },
		YOU_GOAL = { "GOOOAL! {me} scores! {h}-{a}!", "What a strike! {me} — and it's in the net! {h}-{a}!", "{me} puts it in the top corner! {h}-{a}!" },
		YOU_SAVE = { "{me} shoots — saved by the keeper!", "A shot from {me}… great save!", "{me} from distance — the keeper has it." },
		YOU_POST = { "{me} shoots — off the woodwork! Inches away…", "The post saves {away} from {me}!", "Crossbar! {me} was so close!" },
		YOU_MISS = { "{me} shoots — off target.", "A shot from {me} — it's wide.", "Not this time from distance — {me} misses." },
		YOU_TACKLED = { "Tackled! {me} held on to it too long.", "The {away} defender gets there — ball lost.", "{me} took too long — and he's dispossessed!" },
		PASS_GOOD = { "Lovely pass from {me}!", "{me} picks out number {n} — that's through!", "A defence-splitting ball from {me}! Number {n} has it!" },
		CROSS_GOOD = { "{me} crosses… number {n} rises!", "Great delivery from {me} — number {n} gets on the end of it!", "{me} lifts it over the top — number {n} jumps!" },
		PASS_FAIL = { "{me}'s pass is cut out — the attack breaks down.", "The pass from {me} doesn't get there — intercepted.", "Read it! {away} cut out {me}'s pass." },
		CROSS_CLEARED = { "{me} crosses — headed away by the defender.", "The cross from {me}… {away} get there first.", "High ball from {me} — the defence deal with it." },
		PASS_MISS = { "A loose ball from {me} — it runs away.", "{me} can't find his teammate.", "{me}'s pass goes to nobody." },
		ASSIST_GOAL = { "GOAL! Number {n} finishes {me}'s pass! {h}-{a}!", "An assist for {me}! Number {n} scores — {h}-{a}!", "{me} sets it up, number {n} buries it! {h}-{a}!" },
		HEADER_GOAL = { "HEADED GOAL! Number {n} from {me}'s cross! {h}-{a}!", "Cross from {me} — header — GOAL! {h}-{a}!", "Number {n} heads it into the corner! Assist {me}! {h}-{a}!" },
		MATE_SAVE = { "Number {n} shoots from {me}'s pass — the keeper parries!", "Saved! Number {n} couldn't beat the keeper.", "Number {n} shoots… the {away} keeper is alert." },
		MATE_MISS = { "Number {n} shoots from {me}'s pass — wide.", "A fine ball from {me}, but number {n} misses the target.", "Number {n} scuffs it after {me}'s pass." },
		HEADER_SAVE = { "Number {n}'s header — caught by the keeper!", "Number {n} heads it… saved!", "Cross from {me}, header — the keeper is there." },
		HEADER_MISS = { "Number {n} heads it over.", "Number {n}'s header goes wide.", "Cross from {me}, but number {n} can't direct the header." },
		TACTIC_EFFORT_1 = { "{me} is saving his energy.", "{me} eases off a little." },
		TACTIC_EFFORT_2 = { "{me} plays at a steady pace.", "{me} keeps a normal rhythm." },
		TACTIC_EFFORT_3 = { "{me} is giving everything!", "{me} is running all over the pitch!" },
		TACTIC_ATTACK = { "{me} joins the attack.", "{me} pushes up closer to the {away} goal." },
		TACTIC_DEFENSE = { "{me} drops back to help the defence.", "{me} focuses on defending." },
		STAMINA_EMPTY = { "{me} is spent — no more full effort.", "Out of gas — {me} can only jog now." },
	},
}

-- Match screen labels.
local UI = {
	RU = {
		Moment = "МОМЕНТ %d",
		YourMoment = "ТВОЙ МОМЕНТ!",
		Commentator = "КОММЕНТАТОР",
		Live = "LIVE",
		YourPlayer = "ТВОЙ ИГРОК",
		Stamina = "ВЫНОСЛИВОСТЬ",
		Effort = "УСИЛИЯ",
		EffortHint = "Больше сердец — больше моментов, но силы тают быстрее",
		Focus = "ФОКУС",
		Attack = "АТАКА",
		Defense = "ЗАЩИТА",
		FocusHint = "Атака — больше моментов. Защита — меньше голов в наши ворота",
		HighBall = "ВЕРХОМ",
		Pressure = "ЗАЩИТНИКИ БЛИЗКО",
		MomentReady = "Зажми ворота — удар · Веди к партнёру — пас",
		MomentHigh = "Верхом: веди к партнёру в штрафной — навес",
		MomentHolding = "Отпусти, чтобы ударить",
		MomentPassHolding = "Отпусти — пас",
		MomentCrossHolding = "Отпусти — навес",
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
		Moment = "MOMENT %d",
		YourMoment = "YOUR MOMENT!",
		Commentator = "COMMENTATOR",
		Live = "LIVE",
		YourPlayer = "YOUR PLAYER",
		Stamina = "STAMINA",
		Effort = "EFFORT",
		EffortHint = "More hearts: more moments, but stamina drains faster",
		Focus = "FOCUS",
		Attack = "ATTACK",
		Defense = "DEFENSE",
		FocusHint = "Attack: more moments. Defense: fewer goals conceded",
		HighBall = "HIGH BALL",
		Pressure = "DEFENDERS CLOSING IN",
		MomentReady = "Hold on the goal to shoot · Drag to a teammate to pass",
		MomentHigh = "High ball: drag to a teammate in the box to cross",
		MomentHolding = "Release to shoot",
		MomentPassHolding = "Release to pass",
		MomentCrossHolding = "Release to cross",
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

-- A random variant of the line with its placeholders filled in, never the same variant twice in a
-- row for a key.
local lastVariant: { [string]: number } = {}
function Commentary.line(key: string, params: { [string]: any }): string
	local variants = LINES[Commentary.language()][key]
	if not variants then
		return ""
	end
	local index = math.random(1, #variants)
	if #variants > 1 and index == lastVariant[key] then
		index = index % #variants + 1
	end
	lastVariant[key] = index
	return (string.gsub(variants[index], "{(%w+)}", function(name)
		local value = params[name]
		return if value ~= nil then tostring(value) else ""
	end))
end

-- Sound id for the line if a voice file was added, otherwise nil.
function Commentary.voice(key: string): string?
	return Commentary.Voice[Commentary.language()][key]
end

-- Every line key, for checks (tools/sim).
function Commentary.keys(language: string): { [string]: { string } }
	return LINES[language]
end

return Commentary
