-- Turns the packed images in ReplicatedStorage.Shared.Images (made by tools/assets/build_images.py)
-- into EditableImages and shows them wherever the server tagged an instance:
--   CollectionService tag "NfsImage" + attribute Image = "<Module>/<Key>", e.g. "Banners/Logo".
-- ImageLabels get ImageContent and become visible; Decals get TextureContent.
-- If EditableImage is unavailable (published place without "Allow Mesh / Image APIs", or the
-- device's memory budget is used up) nothing breaks: the tagged objects keep their plain fallback look.

local AssetService = game:GetService("AssetService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TAG = "NfsImage"

local ImageLoader = {}

local imagesFolder = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Images")
local modules: { [string]: { [string]: string } } = {}
local cache: { [string]: Content | false } = {}
local disabledReason: string? = nil

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_VALUE = {}
for i = 1, 64 do
	B64_VALUE[string.byte(B64, i)] = i - 1
end

local function base64Decode(text: string): buffer
	text = string.gsub(text, "[^%w%+/]", "") -- drop line breaks and '=' padding
	local length = #text
	local out = buffer.create(length * 3 // 4)
	local o = 0
	for i = 1, length - 3, 4 do
		local a, b, c, d = string.byte(text, i, i + 3)
		local n = B64_VALUE[a] * 262144 + B64_VALUE[b] * 4096 + B64_VALUE[c] * 64 + B64_VALUE[d]
		buffer.writeu8(out, o, n // 65536)
		buffer.writeu8(out, o + 1, n // 256 % 256)
		buffer.writeu8(out, o + 2, n % 256)
		o += 3
	end
	local rest = length % 4
	if rest >= 2 then
		local i = length - rest + 1
		local n = B64_VALUE[string.byte(text, i)] * 262144 + B64_VALUE[string.byte(text, i + 1)] * 4096
		if rest == 3 then
			n += B64_VALUE[string.byte(text, i + 2)] * 64
		end
		buffer.writeu8(out, o, n // 65536)
		if rest == 3 then
			buffer.writeu8(out, o + 1, n // 256 % 256)
		end
	end
	return out
end

-- Packed format: u16 width, u16 height, u16 palette size, palette (RGBA bytes), then LZ tokens:
-- byte c < 128 -> c+1 literal indices follow; c >= 128 -> copy c-125 indices from u16 offset back.
function ImageLoader.decode(packed: string): (number, number, buffer)
	local data = base64Decode(packed)
	local width = buffer.readu16(data, 0)
	local height = buffer.readu16(data, 2)
	local colors = buffer.readu16(data, 4)
	local paletteStart = 6
	local pos = paletteStart + colors * 4
	local dataEnd = buffer.len(data)

	local count = width * height
	local indices = buffer.create(count)
	local o = 0
	while pos < dataEnd and o < count do
		local token = buffer.readu8(data, pos)
		pos += 1
		if token < 128 then
			local n = token + 1
			buffer.copy(indices, o, data, pos, n)
			pos += n
			o += n
		else
			local n = token - 125
			local from = o - buffer.readu16(data, pos)
			pos += 2
			if o - from >= n then
				buffer.copy(indices, o, indices, from, n)
			else -- overlapping run: copy byte by byte so it repeats
				for k = 0, n - 1 do
					buffer.writeu8(indices, o + k, buffer.readu8(indices, from + k))
				end
			end
			o += n
		end
	end
	assert(o == count, "image data is truncated")

	local pixels = buffer.create(count * 4)
	for i = 0, count - 1 do
		-- Palette entries are RGBA bytes, so a little-endian u32 copy keeps the byte order.
		buffer.writeu32(pixels, i * 4, buffer.readu32(data, paletteStart + buffer.readu8(indices, i) * 4))
	end
	return width, height, pixels
end

local function packedData(key: string): string?
	local moduleName, imageName = string.match(key, "^([^/]+)/(.+)$")
	if not moduleName then
		return nil
	end
	local images = modules[moduleName]
	if not images then
		local module = imagesFolder:FindFirstChild(moduleName)
		if not (module and module:IsA("ModuleScript")) then
			return nil
		end
		images = require(module) :: any
		modules[moduleName] = images
	end
	return images[imageName]
end

-- Returns a Content for the image, or nil if it can't be shown. Each image is decoded once
-- and the same EditableImage is shared by every object that shows it.
function ImageLoader.get(key: string): Content?
	local cached = cache[key]
	if cached ~= nil then
		return cached or nil
	end
	if disabledReason then
		return nil
	end
	local packed = packedData(key)
	if not packed then
		warn("[ImageLoader] Unknown image:", key)
		cache[key] = false
		return nil
	end
	local ok, result = pcall(function()
		local width, height, pixels = ImageLoader.decode(packed)
		local image = AssetService:CreateEditableImage({ Size = Vector2.new(width, height) })
		if not image then
			error("device image memory budget is used up", 0)
		end
		image:WritePixelsBuffer(Vector2.zero, image.Size, pixels)
		return Content.fromObject(image)
	end)
	if not ok then
		-- Usually the experience setting is off; stop trying so we warn only once.
		disabledReason = tostring(result)
		warn("[ImageLoader] Images unavailable, using plain fallbacks (" .. disabledReason .. "). In a published game enable Game Settings → Security → Allow Mesh / Image APIs.")
		cache[key] = false
		return nil
	end
	cache[key] = result
	return result
end

local function apply(instance: Instance)
	local key = instance:GetAttribute("Image")
	if type(key) ~= "string" then
		return
	end
	local content = ImageLoader.get(key)
	if not content then
		return
	end
	if instance:IsA("ImageLabel") then
		instance.ImageContent = content
		instance.Visible = true
	elseif instance:IsA("Decal") then
		instance.TextureContent = content
	end
end

-- Fills every tagged object now and as new ones replicate. Decoding is spread over frames.
function ImageLoader.watch()
	local queue = {}
	local running = false
	local function push(instance: Instance)
		table.insert(queue, instance)
		if running then
			return
		end
		running = true
		task.spawn(function()
			while #queue > 0 do
				local item = table.remove(queue, 1)
				local key = item:GetAttribute("Image")
				local fresh = type(key) == "string" and cache[key] == nil
				apply(item)
				if fresh then
					task.wait() -- one new decode per frame keeps the start-up smooth
				end
			end
			running = false
		end)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(push)
	for _, instance in CollectionService:GetTagged(TAG) do
		push(instance)
	end
end

ImageLoader.TAG = TAG

return ImageLoader
