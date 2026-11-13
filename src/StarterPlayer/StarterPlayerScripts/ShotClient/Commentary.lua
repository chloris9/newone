-- Commentator and the match screens' texts, in Russian and English. Every key has a few variants so
-- matches don't read the same; placeholders:
--   {home} {away} our club and the opponent, {me} the player's surname, {n} a teammate's number,
--   {h} {a} the score.
-- The menus and training are Russian, so the match is too (LANGUAGE); set it to "AUTO" to pick by
-- the account's language and country instead.
-- Voice: put an uploaded sound id per key into Commentary.Voice[language] to have the line spoken.

local LocalizationService = game:GetService("LocalizationService")
local Players = game:GetService("Players")

local Commentary = {}

local LANGUAGE = "RU" -- "RU" | "EN" | "AUTO"

-- Countries where AUTO speaks Russian when the account language isn't Russian itself.
local RUSSIAN_COUNTRIES = { RU = true, BY = true, KZ = true, KG = true }

-- How the feed paints each line: US (our play), THEM, ME (your chance), GOAL, CONCEDE, NEUTRAL.
local KIND = {
	KICKOFF = "NEUTRAL", HALFTIME = "NEUTRAL", LATE = "NEUTRAL",
	FULLTIME_WIN = "GOAL", FULLTIME_DRAW = "NEUTRAL", FULLTIME_LOSS = "CONCEDE",
	OPP_ATTACK = "THEM", OPP_GOAL = "CONCEDE", OPP_SAVE = "US", OPP_MISS = "THEM",
	TEAM_ATTACK = "US", TEAM_GOAL = "GOAL", TEAM_MISS = "US",
	BUILDUP_US = "US", BUILDUP_THEM = "THEM", MIDFIELD = "NEUTRAL", FOUL_US = "US", FOUL_THEM = "THEM",
	CORNER_US = "US", CORNER_THEM = "THEM", OFFSIDE_US = "US", OFFSIDE_THEM = "THEM", CROWD = "NEUTRAL",
	KEEPER_US = "US", YELLOW_THEM = "THEM", YELLOW_US = "US", SUB_THEM = "THEM",
	ME_RUN = "ME", ME_CALL = "ME", TEAM_PRESS = "US", ME_TRACK = "ME", TEAM_DEEP = "US", ME_TACKLE = "ME",
	ME_TIRED = "NEUTRAL", ME_EXHAUSTED = "CONCEDE",
	CHANCE = "ME", BUILD_ONBALL = "ME", BUILD_RECEIVE = "ME", PROMPT = "ME",
	YOU_GOAL = "GOAL", YOU_SAVE = "ME", YOU_POST = "ME", YOU_MISS = "ME", YOU_BLOCKED = "THEM", YOU_TACKLED = "THEM",
	PASS_GOOD = "ME", CROSS_GOOD = "ME", ONETWO = "ME", PASS_FAIL = "THEM", CROSS_CLEARED = "THEM",
	PASS_MISS = "THEM", PASS_HEAVY = "THEM", CHANCE_LOST = "NEUTRAL",
	ASSIST_GOAL = "GOAL", HEADER_GOAL = "GOAL", MATE_SAVE = "ME", MATE_MISS = "ME", HEADER_SAVE = "ME", HEADER_MISS = "ME",
	TACTIC_EFFORT_1 = "NEUTRAL", TACTIC_EFFORT_2 = "NEUTRAL", TACTIC_EFFORT_3 = "ME", TACTIC_ATTACK = "ME", TACTIC_DEFENSE = "NEUTRAL",
	STAMINA_EMPTY = "CONCEDE",
}

local LINES = {
	RU = {
		-- Whistles
		KICKOFF = { "Свисток! {home} против {away} — матч начался!", "Поехали! {home} принимает {away}.", "Мяч в игре! {home} и {away} начинают." },
		HALFTIME = { "Перерыв. На табло {h}:{a}.", "Первый тайм позади — {h}:{a}.", "Команды уходят в раздевалку при счёте {h}:{a}." },
		LATE = { "Последние минуты! Всё решается сейчас.", "Время на исходе — {h}:{a} на табло.", "Арбитр уже поглядывает на часы…" },
		FULLTIME_WIN = { "Финальный свисток! {home} побеждает — {h}:{a}!", "Всё! Победа {home}, {h}:{a}!", "Конец матча! Три очка у {home} — {h}:{a}!" },
		FULLTIME_DRAW = { "Финальный свисток. Ничья — {h}:{a}.", "Матч окончен, победителя нет: {h}:{a}.", "Очки поделены: {h}:{a}." },
		FULLTIME_LOSS = { "Финальный свисток. {away} увозит победу — {h}:{a}.", "Всё кончено: {h}:{a} в пользу {away}.", "Сегодня не наш день: {h}:{a}." },
		-- Chances at both ends
		OPP_ATTACK = { "{away} быстро переходит в атаку…", "Опасный проход {away} по флангу!", "{away} навешивает в нашу штрафную…", "Контратака {away}! Трое против двоих…" },
		OPP_GOAL = { "ГОЛ… {away} забивает. {h}:{a}.", "Пропустили! {away} реализует момент — {h}:{a}.", "Мяч в наших воротах. {h}:{a}." },
		OPP_SAVE = { "Вратарь тащит! Какая реакция!", "Удар в створ — но наш кипер на месте!", "Сейв! Вратарь переводит на угловой." },
		OPP_MISS = { "Удар… мимо ворот.", "Выше перекладины! Выдыхаем.", "Защитник в последний момент выносит мяч!" },
		TEAM_ATTACK = { "{home} разыгрывает мяч у штрафной…", "Номер {n} врывается в штрафную!", "Быстрая атака {home} через центр!" },
		TEAM_GOAL = { "ГОЛ! Номер {n} забивает за {home}! {h}:{a}!", "{home} забивает! Отличился номер {n} — {h}:{a}!", "Номер {n} — и мяч в сетке! {h}:{a}!" },
		TEAM_MISS = { "Номер {n} бьёт — рядом со штангой.", "Не попал! Номер {n} хватается за голову.", "Вратарь {away} забирает удар номера {n}." },
		-- General play
		BUILDUP_US = { "{home} спокойно катает мяч в центре поля.", "Наши защитники ищут продольную передачу.", "{home} контролирует мяч, соперник отошёл назад." },
		BUILDUP_THEM = { "{away} владеет мячом и не торопится.", "Соперник перекатывает мяч от фланга к флангу.", "{away} ищет щель в нашей обороне." },
		MIDFIELD = { "Борьба в центре поля, мяч переходит из ног в ноги.", "Много единоборств — никто не уступает.", "Игра идёт на встречных курсах." },
		FOUL_US = { "Фол на номере {n}! Штрафной для {home}.", "Нашего игрока сбивают — свисток арбитра.", "Грубо! Номер {n} на газоне, но поднимается." },
		FOUL_THEM = { "Наш фол в центре поля, штрафной для {away}.", "Арбитр свистит: нарушение со стороны {home}.", "Подкат сзади — штрафной у наших ворот." },
		CORNER_US = { "Угловой для {home}! Высокие игроки идут вперёд.", "Подача с углового… защитник выбивает.", "Угловой — мяч пролетает через всю штрафную." },
		CORNER_THEM = { "Угловой у наших ворот, внимание!", "Подача {away} с углового — вратарь забирает.", "{away} разыгрывает угловой коротко." },
		OFFSIDE_US = { "Флажок поднят — номер {n} в офсайде.", "Офсайд! Атака {home} остановлена.", "Чуть раньше рванул — вне игры." },
		OFFSIDE_THEM = { "Офсайд у {away}! Оборона сработала чётко.", "Ловушка сработала — соперник вне игры.", "Флажок! Атака {away} прервана." },
		CROWD = { "Трибуны поют! Атмосфера — огонь.", "Болельщики {home} требуют гола!", "Стадион гудит — слышно на весь город." },
		KEEPER_US = { "Наш вратарь выбивает мяч далеко вперёд.", "Кипер {home} начинает атаку длинным пасом.", "Вратарь не спешит, тянет время." },
		YELLOW_THEM = { "Жёлтая карточка игроку {away}!", "Предупреждение сопернику за срыв атаки.", "Арбитр достаёт жёлтую — {away} на грани." },
		YELLOW_US = { "Жёлтая карточка нашему игроку. Аккуратнее!", "Предупреждение {home} за грубый подкат.", "Карточка — номер {n} в зоне риска." },
		SUB_THEM = { "{away} проводит замену — свежие ноги.", "У соперника замена в атаке.", "Тренер {away} что-то меняет." },
		-- You off the ball
		ME_RUN = { "{me} делает рывок за спину защитникам!", "{me} открывается, требует мяч!", "{me} постоянно в движении — защита нервничает." },
		ME_CALL = { "{me} показывает номеру {n}: «Давай сюда!»", "{me} ищет пространство между линиями.", "{me} смещается в полузону — там свободно." },
		TEAM_PRESS = { "{home} прессингует высоко!", "Наши давят — {away} не может выйти из обороны.", "Высокий прессинг {home} приносит плоды." },
		ME_TRACK = { "{me} возвращается помогать защите.", "{me} закрывает фланг — тренер доволен.", "{me} без устали работает в отборе." },
		TEAM_DEEP = { "{home} отошли в глубокую оборону.", "Наши играют от обороны и ждут шанса.", "Компактная оборона {home} — не пройти." },
		ME_TACKLE = { "{me} отбирает мяч! Отличный подкат!", "Перехват от {me} — атака соперника сорвана!", "{me} выигрывает единоборство в центре!" },
		ME_TIRED = { "{me} заметно подустал…", "{me} тяжело дышит — силы на исходе.", "Видно, что {me} отдал много сил." },
		ME_EXHAUSTED = { "{me} еле передвигает ноги!", "{me} выжат как лимон…", "У {me} совсем не осталось сил." },
		-- Your chance: the build-up, then the result
		CHANCE = { "Шанс на прорыв для {me}…", "{me} получает шанс!", "Назревает момент для {me}…" },
		BUILD_ONBALL = { "Прекрасный проход с мячом в исполнении {me}", "{me} обыгрывает соперника и рвётся вперёд!", "{me} подхватывает отскок — и вперёд!" },
		BUILD_RECEIVE = { "Номер {n} ищет передачей {me}…", "Номер {n} поднимает голову и видит {me}", "Пас номера {n} в ноги {me}…" },
		PROMPT = { "Вот шанс нанести удар!", "Что придумает {me}?", "Время принимать решение!" },
		YOU_GOAL = { "ГОООЛ! {me} забивает! {h}:{a}!", "Какой удар! {me} — и мяч в сетке! {h}:{a}!", "{me} кладёт мяч в угол! {h}:{a}!" },
		YOU_SAVE = { "{me} бьёт — вратарь спасает!", "Удар {me}… сейв!", "{me} пробивает — кипер на месте." },
		YOU_POST = { "{me} бьёт — каркас ворот! Сантиметры…", "Штанга спасает {away} после удара {me}!", "Перекладина! {me} был так близко!" },
		YOU_MISS = { "{me} бьёт — мимо.", "Удар {me} — неточно.", "Не получилось — {me} промахивается." },
		YOU_BLOCKED = { "Удар {me} — блок защитника!", "Защитник бросается под удар {me}!", "Мяч попадает в защитника — удар заблокирован." },
		YOU_TACKLED = { "Отбор! {me} передержал мяч.", "Защитник {away} успевает — мяч потерян.", "{me} слишком долго думал — подкат!" },
		PASS_GOOD = { "Отличный пас {me}!", "{me} находит номер {n} — передача прошла!", "Пас-разрез от {me}! Номер {n} с мячом!" },
		CROSS_GOOD = { "Навес от {me}… номер {n} в воздухе!", "Отличная подача {me} — номер {n} на мяче!", "{me} кидает верхом — номер {n} выпрыгивает!" },
		ONETWO = { "Стенка с номером {n}! {me} снова с мячом!", "Номер {n} возвращает мяч — {me} в выгодной позиции!", "Игра в стенку! {me} уже у штрафной!" },
		PASS_FAIL = { "Пас {me} перехвачен.", "Передача {me} не дошла — защитник на месте.", "Перехват! {away} читает пас {me}." },
		CROSS_CLEARED = { "Навес {me} — защитник выбивает головой.", "Подача {me}… защита {away} сыграла первой.", "Верховой мяч от {me} — оборона справилась." },
		PASS_MISS = { "Передача {me} уходит в никуда.", "{me} не попал в партнёра.", "Пас {me} в пустоту." },
		PASS_HEAVY = { "Слишком сильно! Номер {n} не справился с мячом.", "Пас {me} чересчур сильный — мяч отскакивает.", "Номер {n} не удержал мяч после паса {me}." },
		CHANCE_LOST = { "Шанс упущен.", "Момент упущен…", "Атака заглохла." },
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
		HALFTIME = { "Half-time. It's {h}-{a}.", "That's the first half done — {h}-{a}.", "The teams head in at {h}-{a}." },
		LATE = { "The final minutes! It all comes down to this.", "Time is running out — {h}-{a} on the board.", "The referee is checking his watch…" },
		FULLTIME_WIN = { "Full time! {home} win it, {h}-{a}!", "It's all over! Victory for {home}, {h}-{a}!", "That's it! Three points for {home} — {h}-{a}!" },
		FULLTIME_DRAW = { "Full time. Honours even — {h}-{a}.", "The final whistle, and nothing to separate them: {h}-{a}.", "Points shared: {h}-{a}." },
		FULLTIME_LOSS = { "Full time. {away} take the points — {h}-{a}.", "It's over: {h}-{a} to {away}.", "Not our day: {h}-{a}." },
		OPP_ATTACK = { "{away} break forward quickly…", "Dangerous run from {away} down the wing!", "{away} swing a ball into our box…", "Counter-attack for {away}! Three on two…" },
		OPP_GOAL = { "GOAL… {away} score. {h}-{a}.", "They've conceded! {away} take their chance — {h}-{a}.", "It's in our net. {h}-{a}." },
		OPP_SAVE = { "The keeper saves! What reflexes!", "On target — but our keeper is there!", "Save! Tipped round for a corner." },
		OPP_MISS = { "The shot… wide of the goal.", "Over the bar! We can breathe again.", "A last-ditch clearance!" },
		TEAM_ATTACK = { "{home} work it around the edge of the box…", "Number {n} bursts into the box!", "Quick attack from {home} through the middle!" },
		TEAM_GOAL = { "GOAL! Number {n} scores for {home}! {h}-{a}!", "{home} score! Number {n} with the finish — {h}-{a}!", "Number {n} — and it's in! {h}-{a}!" },
		TEAM_MISS = { "Number {n} shoots — just past the post.", "Missed! Number {n} can't believe it.", "The {away} keeper gathers number {n}'s shot." },
		BUILDUP_US = { "{home} knock it about calmly in midfield.", "Our defenders look for the long ball.", "{home} in control, the opposition sitting deep." },
		BUILDUP_THEM = { "{away} have the ball and take their time.", "They move it from flank to flank.", "{away} probing for a gap in our defence." },
		MIDFIELD = { "A battle in midfield, the ball changing hands.", "Lots of duels — nobody giving an inch.", "End-to-end stuff now." },
		FOUL_US = { "Foul on number {n}! Free kick to {home}.", "Our man is brought down — the whistle goes.", "Ouch! Number {n} is down, but he's back up." },
		FOUL_THEM = { "Our foul in midfield, free kick to {away}.", "The referee blows: foul by {home}.", "A tackle from behind — free kick near our goal." },
		CORNER_US = { "Corner to {home}! The big men go forward.", "In comes the corner… headed clear.", "The corner flies right across the box." },
		CORNER_THEM = { "Corner at our end, stay switched on!", "{away} swing in the corner — the keeper claims it.", "{away} take the corner short." },
		OFFSIDE_US = { "The flag is up — number {n} is offside.", "Offside! {home}'s attack is stopped.", "Went a fraction too early — offside." },
		OFFSIDE_THEM = { "Offside against {away}! Our back line got that right.", "The trap works — they're offside.", "Flag! {away}'s attack comes to nothing." },
		CROWD = { "The stands are singing! What an atmosphere.", "The {home} fans want a goal!", "The stadium is rocking." },
		KEEPER_US = { "Our keeper launches it long.", "The {home} keeper starts the attack with a long ball.", "The keeper takes his time over that one." },
		YELLOW_THEM = { "Yellow card for {away}!", "A booking for stopping the attack.", "Out comes the yellow — {away} living dangerously." },
		YELLOW_US = { "A yellow card for one of ours. Careful now!", "Booking for {home} after a heavy tackle.", "Yellow — number {n} has to be careful." },
		SUB_THEM = { "{away} make a change — fresh legs.", "An attacking substitution for the opposition.", "The {away} coach is shaking things up." },
		ME_RUN = { "{me} darts in behind the defence!", "{me} finds space and calls for it!", "{me} never stops moving." },
		ME_CALL = { "{me} points to number {n}: \"Here!\"", "{me} drifts between the lines.", "{me} moves into the half-space — wide open." },
		TEAM_PRESS = { "{home} are pressing high!", "We're squeezing them — {away} can't get out.", "The high press from {home} is paying off." },
		ME_TRACK = { "{me} tracks back to help the defence.", "{me} covers the flank.", "{me} working tirelessly without the ball." },
		TEAM_DEEP = { "{home} sit in a deep block.", "We defend first and wait for our chance.", "A compact {home} defence — no way through." },
		ME_TACKLE = { "{me} wins it back! Great tackle!", "Interception from {me}!", "{me} wins the duel in midfield!" },
		ME_TIRED = { "{me} is starting to tire…", "{me} is breathing hard.", "You can see {me} has given a lot." },
		ME_EXHAUSTED = { "{me} can barely run!", "{me} is running on empty…", "{me} has nothing left in the tank." },
		CHANCE = { "A chance to break through for {me}…", "{me} gets a chance!", "Something is brewing for {me}…" },
		BUILD_ONBALL = { "Lovely run with the ball from {me}", "{me} beats his man and drives forward!", "{me} picks up the loose ball — and he's away!" },
		BUILD_RECEIVE = { "Number {n} looks for {me}…", "Number {n} looks up and sees {me}", "Number {n} plays it into {me}'s feet…" },
		PROMPT = { "Here's a chance to shoot!", "What will {me} do?", "Decision time!" },
		YOU_GOAL = { "GOOOAL! {me} scores! {h}-{a}!", "What a strike! {me} — and it's in the net! {h}-{a}!", "{me} puts it in the corner! {h}-{a}!" },
		YOU_SAVE = { "{me} shoots — saved by the keeper!", "A shot from {me}… great save!", "{me} lets fly — the keeper has it." },
		YOU_POST = { "{me} shoots — off the woodwork! Inches away…", "The post saves {away} from {me}!", "Crossbar! {me} was so close!" },
		YOU_MISS = { "{me} shoots — off target.", "A shot from {me} — it's wide.", "Not this time — {me} misses." },
		YOU_BLOCKED = { "{me} shoots — blocked!", "A defender throws himself in front of {me}'s shot!", "It hits the defender — blocked." },
		YOU_TACKLED = { "Tackled! {me} held on to it too long.", "The {away} defender gets there — ball lost.", "{me} took too long — dispossessed!" },
		PASS_GOOD = { "Lovely pass from {me}!", "{me} picks out number {n} — that's through!", "A defence-splitting ball from {me}! Number {n} has it!" },
		CROSS_GOOD = { "{me} crosses… number {n} rises!", "Great delivery from {me} — number {n} gets on the end of it!", "{me} lifts it over the top — number {n} jumps!" },
		ONETWO = { "A one-two with number {n}! {me} has it again!", "Number {n} gives it back — {me} is in a great spot!", "Give and go! {me} is at the edge of the box!" },
		PASS_FAIL = { "{me}'s pass is cut out.", "The pass from {me} doesn't get there — intercepted.", "Read it! {away} cut out {me}'s pass." },
		CROSS_CLEARED = { "{me} crosses — headed away.", "The cross from {me}… {away} get there first.", "High ball from {me} — the defence deal with it." },
		PASS_MISS = { "A loose ball from {me} — it runs away.", "{me} can't find his teammate.", "{me}'s pass goes to nobody." },
		PASS_HEAVY = { "Too hard! Number {n} can't control it.", "{me}'s pass is overhit — it bounces away.", "Number {n} can't hold on to {me}'s pass." },
		CHANCE_LOST = { "Chance gone.", "The moment has passed…", "The attack fizzles out." },
		ASSIST_GOAL = { "GOAL! Number {n} finishes {me}'s pass! {h}-{a}!", "An assist for {me}! Number {n} scores — {h}-{a}!", "{me} sets it up, number {n} buries it! {h}-{a}!" },
		HEADER_GOAL = { "HEADED GOAL! Number {n} from {me}'s cross! {h}-{a}!", "Cross from {me} — header — GOAL! {h}-{a}!", "Number {n} heads it into the corner! Assist {me}! {h}-{a}!" },
		MATE_SAVE = { "Number {n} shoots from {me}'s pass — the keeper parries!", "Saved! Number {n} couldn't beat the keeper.", "Number {n} shoots… the {away} keeper is alert." },
		MATE_MISS = { "Number {n} shoots from {me}'s pass — wide.", "A fine ball from {me}, but number {n} misses.", "Number {n} scuffs it after {me}'s pass." },
		HEADER_SAVE = { "Number {n}'s header — caught!", "Number {n} heads it… saved!", "Cross from {me}, header — the keeper is there." },
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
		Commentator = "КОММЕНТАТОР",
		Live = "LIVE",
		Ticker = { "ЛИГА NEW FOOTBALL STAR · ПРЯМОЙ ЭФИР", "ТРИБУНЫ ЗАПОЛНЕНЫ ДО ОТКАЗА", "СОВЕТ: БЕРЕГИ ЭНЕРГИЮ К КОНЦОВКЕ МАТЧА", "СОВЕТ: ЗАЩИТНИК НА ПУТИ — ЗАКРУТИ МЯЧ ИЛИ ОТДАЙ ПАС" },
		Play = "В ИГРУ",
		PlayHint = "Твой момент!",
		Energy = "ЭНЕРГИЯ",
		Work = "РАБОТА",
		Focus = "ФОКУС",
		EffortNames = { "Экономно", "Обычно", "На максимум" },
		EffortInfo = { "Меньше моментов, силы тратятся медленно", "Обычный темп игры", "Больше моментов и времени на решение, силы тают быстро" },
		Attack = "АТАКА",
		Defense = "ЗАЩИТА",
		AttackInfo = "Больше моментов у ворот соперника",
		DefenseInfo = "Меньше голов в наши ворота",
		Choose = "ВЫБЕРИ",
		YourPlayer = "ТВОЙ ИГРОК",
		Rating = "ОЦЕНКА",
		Goals = "ГОЛЫ",
		Assists = "ПАСЫ",
		Shots = "УДАРЫ",
		Moments = "МОМЕНТЫ",
		Timeline = "ХОД МАТЧА",
		Speed = "×2",
		-- During a moment
		AimHint = "Веди от мяча: к партнёру — пас, в ворота — удар",
		AimShot = "УДАР ПО ВОРОТАМ",
		AimShotBlocked = "ЗАЩИТНИК НА ПУТИ — ЗАКРУТИ, ПЕРЕБРОСЬ ИЛИ ЦЕЛЬСЯ МИМО",
		AimPass = "ПАС НОМЕРУ %d",
		AimSpace = "ПАС НА ХОД",
		AimShort = "Дальше от мяча",
		StrikeHint = "БЕЙ ПО МЯЧУ!",
		StrikeLow = "Ниже центра — верхом",
		StrikeHigh = "Выше центра — низом",
		StrikeSide = "Сбоку — закрутка в обход",
		Pressure = "ЗАЩИТНИК БЛИЖЕ",
		Banner = { GOAL = "ГОЛ!", SAVE = "СЕЙВ", POST = "ШТАНГА!", MISS = "МИМО", BLOCKED = "БЛОК", TACKLED = "ОТБОР", INTERCEPTED = "ПЕРЕХВАТ", CLEARED = "ВЫНОС", ASTRAY = "НЕТОЧНО", TOO_HARD = "СИЛЬНО", ONETWO = "СТЕНКА!", PASS = "ПАС!", CROSS = "НАВЕС!" },
		-- Full time
		Win = "ПОБЕДА!",
		Draw = "НИЧЬЯ",
		Loss = "ПОРАЖЕНИЕ",
		Xp = "+%d XP",
		Level = "УРОВЕНЬ %d",
		ShotsLine = "Удары: %d  ·  Точные пасы: %d из %d",
		Continue = "ПРОДОЛЖИТЬ  ›",
	},
	EN = {
		Commentator = "COMMENTATOR",
		Live = "LIVE",
		Ticker = { "NEW FOOTBALL STAR LEAGUE · LIVE", "A FULL HOUSE TONIGHT", "TIP: SAVE ENERGY FOR THE FINAL MINUTES", "TIP: DEFENDER IN THE WAY? CURL IT OR PASS" },
		Play = "PLAY",
		PlayHint = "Your moment!",
		Energy = "ENERGY",
		Work = "WORK RATE",
		Focus = "FOCUS",
		EffortNames = { "Easy", "Normal", "All out" },
		EffortInfo = { "Fewer moments, stamina lasts", "Normal pace", "More moments and more time to decide, stamina drains fast" },
		Attack = "ATTACK",
		Defense = "DEFENSE",
		AttackInfo = "More moments at the other end",
		DefenseInfo = "Fewer goals conceded",
		Choose = "CHOOSE",
		YourPlayer = "YOUR PLAYER",
		Rating = "RATING",
		Goals = "GOALS",
		Assists = "ASSISTS",
		Shots = "SHOTS",
		Moments = "MOMENTS",
		Timeline = "MATCH",
		Speed = "×2",
		AimHint = "Drag from the ball: to a teammate to pass, to the goal to shoot",
		AimShot = "SHOT AT GOAL",
		AimShotBlocked = "DEFENDER IN THE WAY — CURL IT, CHIP IT OR AIM PAST HIM",
		AimPass = "PASS TO NUMBER %d",
		AimSpace = "PASS INTO SPACE",
		AimShort = "Drag further from the ball",
		StrikeHint = "HIT THE BALL!",
		StrikeLow = "Below centre — lofted",
		StrikeHigh = "Above centre — low",
		StrikeSide = "Side — curls round",
		Pressure = "DEFENDER CLOSING",
		Banner = { GOAL = "GOAL!", SAVE = "SAVED", POST = "POST!", MISS = "WIDE", BLOCKED = "BLOCKED", TACKLED = "TACKLED", INTERCEPTED = "INTERCEPTED", CLEARED = "CLEARED", ASTRAY = "LOOSE", TOO_HARD = "TOO HARD", ONETWO = "ONE-TWO!", PASS = "PASS!", CROSS = "CROSS!" },
		Win = "VICTORY!",
		Draw = "DRAW",
		Loss = "DEFEAT",
		Xp = "+%d XP",
		Level = "LEVEL %d",
		ShotsLine = "Shots: %d  ·  Good passes: %d of %d",
		Continue = "CONTINUE  ›",
	},
}

-- Optional voice-over: Commentary.Voice.RU.YOU_GOAL = "rbxassetid://..." and so on.
Commentary.Voice = { RU = {}, EN = {} }

local detected: string? = nil

-- "RU" or "EN".
function Commentary.language(): string
	if detected then
		return detected
	end
	local language = LANGUAGE
	if language == "AUTO" then
		local locale = string.lower(LocalizationService.RobloxLocaleId or "")
		if string.sub(locale, 1, 2) == "ru" then
			language = "RU"
		elseif locale ~= "" and string.sub(locale, 1, 2) ~= "en" then
			language = "EN"
		else
			local ok, country = pcall(function()
				return LocalizationService:GetCountryRegionForPlayerAsync(Players.LocalPlayer)
			end)
			language = if ok and RUSSIAN_COUNTRIES[country] then "RU" else "EN"
		end
	end
	detected = language
	return language
end

function Commentary.ui()
	return UI[Commentary.language()]
end

-- US | THEM | ME | GOAL | CONCEDE | NEUTRAL
function Commentary.kind(key: string): string
	return KIND[key] or "NEUTRAL"
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

-- Every line key, for checks.
function Commentary.keys(language: string): { [string]: { string } }
	return LINES[language]
end

return Commentary
