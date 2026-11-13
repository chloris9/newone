-- Career data shared by the server (validation, saves) and the client (menus, kit preview):
-- the league's eight fictional clubs, which of them a new player can join, and the rules for
-- the player's name and shirt number.

local CareerConfig = {}

local rgb = Color3.fromRGB

CareerConfig.League = {
	Name = "ЛИГА ЗВЁЗД",
	Clubs = 8,
}

CareerConfig.StartOvr = 40 -- GDD: a new player starts around OVR 40

-- Same skin and hair as the training players (PassVisuals), so the preview matches the pitch.
CareerConfig.Skin = rgb(214, 132, 82)
CareerConfig.Hair = rgb(52, 32, 26)
CareerConfig.Boots = rgb(20, 14, 30)

export type Club = {
	id: string,
	name: string,
	short: string, -- crest letters
	ovr: number,
	stars: number, -- 0.5 steps, 5 = top club
	open: boolean, -- can be picked for a new career
	unlockOvr: number?, -- player rating at which a locked club starts to take interest
	shirt: Color3,
	shorts: Color3,
	socks: Color3,
	print: Color3, -- name and number on the shirt
}

-- Strongest first. Only the three weakest clubs sign a 40-rated newcomer; the rest show what
-- the player can grow into.
CareerConfig.Clubs = {
	{ id = "WESTPORT", name = "Westport City", short = "WC", ovr = 66, stars = 5, open = false, unlockOvr = 75,
		shirt = rgb(92, 170, 255), shorts = rgb(245, 245, 250), socks = rgb(92, 170, 255), print = rgb(18, 11, 36) },
	{ id = "NORTHVALE", name = "Northvale FC", short = "NV", ovr = 65, stars = 4.5, open = false, unlockOvr = 70,
		shirt = rgb(240, 240, 248), shorts = rgb(24, 28, 52), socks = rgb(240, 240, 248), print = rgb(24, 28, 52) },
	{ id = "EASTBRIDGE", name = "Eastbridge United", short = "EU", ovr = 64, stars = 4, open = false, unlockOvr = 65,
		shirt = rgb(214, 36, 56), shorts = rgb(245, 245, 250), socks = rgb(214, 36, 56), print = rgb(255, 255, 255) },
	{ id = "REDMONT", name = "Redmont Athletic", short = "RA", ovr = 63, stars = 3.5, open = false, unlockOvr = 60,
		shirt = rgb(128, 26, 52), shorts = rgb(250, 214, 120), socks = rgb(128, 26, 52), print = rgb(250, 214, 120) },
	{ id = "SOUTHGATE", name = "Southgate FC", short = "SG", ovr = 62, stars = 3, open = false, unlockOvr = 55,
		shirt = rgb(34, 150, 84), shorts = rgb(245, 245, 250), socks = rgb(34, 150, 84), print = rgb(255, 255, 255) },
	{ id = "NEWFORD", name = "Newford FC", short = "NF", ovr = 61, stars = 2.5, open = true,
		shirt = rgb(255, 136, 36), shorts = rgb(26, 20, 34), socks = rgb(255, 136, 36), print = rgb(26, 20, 34) },
	{ id = "RIVERSIDE", name = "Riverside Rovers", short = "RR", ovr = 60, stars = 2, open = true,
		shirt = rgb(18, 168, 170), shorts = rgb(20, 36, 70), socks = rgb(20, 36, 70), print = rgb(255, 255, 255) },
	{ id = "ASHFORD", name = "Ashford Town", short = "AT", ovr = 59, stars = 2, open = true,
		shirt = rgb(250, 210, 40), shorts = rgb(26, 20, 34), socks = rgb(250, 210, 40), print = rgb(26, 20, 34) },
} :: { Club }

CareerConfig.Name = {
	MinLength = 2,
	MaxLength = 14,
}

CareerConfig.Number = {
	Min = 1,
	Max = 99,
	Default = 10,
	Picks = { 7, 9, 10, 11, 17, 99 },
}

local clubsById: { [string]: Club } = {}
for _, club in CareerConfig.Clubs do
	clubsById[club.id] = club
end

function CareerConfig.club(id: any): Club?
	return if typeof(id) == "string" then clubsById[id] else nil
end

-- First opponent of the season: the next club below in the table (wrapping round).
function CareerConfig.firstOpponent(club: Club): Club
	for i, other in CareerConfig.Clubs do
		if other == club then
			return CareerConfig.Clubs[i % #CareerConfig.Clubs + 1]
		end
	end
	return CareerConfig.Clubs[1]
end

local function isLetter(code: number): boolean
	return (code >= 65 and code <= 90) -- A-Z
		or (code >= 97 and code <= 122) -- a-z
		or (code >= 0x400 and code <= 0x45F) -- Cyrillic, incl. Ё/ё
end

-- Trims and checks a first or last name. Letters (Latin or Cyrillic), single inner spaces,
-- hyphens and apostrophes. Returns the cleaned name, or nil and an error code:
-- EMPTY | TOO_SHORT | TOO_LONG | BAD_CHARS
function CareerConfig.cleanName(raw: any): (string?, string?)
	if typeof(raw) ~= "string" then
		return nil, "EMPTY"
	end
	if not utf8.len(raw) then
		return nil, "BAD_CHARS"
	end
	local name = string.gsub(string.gsub(raw, "^%s+", ""), "%s+$", "")
	name = string.gsub(name, "%s+", " ")
	local length = utf8.len(name) or 0
	if length == 0 then
		return nil, "EMPTY"
	end
	local letters = 0
	for _, code in utf8.codes(name) do
		if isLetter(code) then
			letters += 1
		elseif code ~= 32 and code ~= 45 and code ~= 39 then -- space, hyphen, apostrophe
			return nil, "BAD_CHARS"
		end
	end
	if letters < CareerConfig.Name.MinLength then
		return nil, "TOO_SHORT"
	end
	if length > CareerConfig.Name.MaxLength then
		return nil, "TOO_LONG"
	end
	return name, nil
end

function CareerConfig.validNumber(value: any): boolean
	return typeof(value) == "number"
		and value == math.floor(value)
		and value >= CareerConfig.Number.Min
		and value <= CareerConfig.Number.Max
end

-- string.upper only handles ASCII; shirts print surnames in capitals, Cyrillic included.
function CareerConfig.upper(text: string): string
	if not utf8.len(text) then
		return string.upper(text)
	end
	local out = {}
	for _, code in utf8.codes(text) do
		if code >= 97 and code <= 122 then
			code -= 32
		elseif code >= 0x430 and code <= 0x44F then
			code -= 0x20
		elseif code >= 0x450 and code <= 0x45F then
			code -= 0x50
		end
		table.insert(out, utf8.char(code))
	end
	return table.concat(out)
end

return CareerConfig
