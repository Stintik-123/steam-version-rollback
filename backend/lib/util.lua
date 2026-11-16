--- Мелкие общие помощники: пути, кэш на диске, лог, безопасный JSON.

local fs = require("fs")
local utils = require("utils")
local logger = require("logger")

-- Millennium встраивает lua-cjson и документирует вход как "json";
-- старые сборки отдавали его же как "cjson". Берём то, что есть.
local ok_json, cjson = pcall(require, "json")
if not ok_json then
	cjson = require("cjson")
end

local util = {}

util.MAX_LOG = 250
local log_ring = {}

function util.is_windows()
	return package.config:sub(1, 1) == "\\" or utils.getenv("OS") == "Windows_NT"
end

--- Папка для кэша и метаданных плагина (не внутри Steam, чтобы не мешать валидации).
function util.data_dir()
	local base
	if util.is_windows() then
		base = utils.getenv("LOCALAPPDATA") or utils.getenv("TEMP") or utils.getenv("USERPROFILE")
	else
		base = utils.getenv("XDG_DATA_HOME") or ((utils.getenv("HOME") or "/tmp") .. "/.local/share")
	end
	local dir = fs.join(base or ".", "VersionRollback")
	if not fs.exists(dir) then
		fs.create_directories(dir)
	end
	return dir
end

function util.now()
	return math.floor(utils.time())
end

--- AppID из CEF иногда приходит как знаковый int32 (актуально для non-Steam ярлыков).
function util.norm_id(v)
	local n = tonumber(v)
	if n == nil then
		return nil
	end
	if n < 0 and n >= -2147483648 then
		n = n + 4294967296
	end
	return string.format("%.0f", n)
end

--- ВАЖНО: manifest GID — 64-битное число. Никогда не превращаем его в number
--- (Lua и JS теряют точность выше 2^53). Всегда строка.
function util.norm_gid(v)
	if v == nil then
		return nil
	end
	local s = tostring(v):gsub("%s", "")
	if s == "" or not s:match("^%d+$") then
		return nil
	end
	return s
end

function util.log(msg)
	msg = tostring(msg)
	logger:info(msg)
	log_ring[#log_ring + 1] = { t = util.now(), msg = msg }
	if #log_ring > util.MAX_LOG then
		table.remove(log_ring, 1)
	end
end

function util.warn(msg)
	logger:warn(tostring(msg))
	util.log("WARN: " .. tostring(msg))
end

function util.err(msg)
	logger:error(tostring(msg))
	util.log("ERROR: " .. tostring(msg))
end

function util.log_tail(n)
	n = n or 60
	local out = {}
	local from = math.max(1, #log_ring - n + 1)
	for i = from, #log_ring do
		out[#out + 1] = log_ring[i]
	end
	return out
end

function util.decode_json(text)
	if type(text) ~= "string" or text == "" then
		return nil, "пустой JSON"
	end
	local decoded, err = cjson.safe.decode(text)
	if decoded == nil then
		return nil, tostring(err)
	end
	return decoded
end

function util.encode_json(tbl)
	local encoded, err = cjson.safe.encode(tbl)
	if encoded == nil then
		util.err("не удалось собрать JSON: " .. tostring(err))
		return "{}"
	end
	return encoded
end

function util.read_file(path)
	if not fs.exists(path) then
		return nil
	end
	local data = utils.read_file(path)
	return data
end

function util.write_file(path, data)
	local parent = fs.parent_path(path)
	if parent and not fs.exists(parent) then
		fs.create_directories(parent)
	end
	local ok, err = utils.write_file(path, data)
	if not ok then
		util.err("не удалось записать " .. tostring(path) .. ": " .. tostring(err))
	end
	return ok and true or false
end

function util.read_json_file(path)
	local raw = util.read_file(path)
	if not raw then
		return nil
	end
	local res = util.decode_json(raw)
	return res
end

function util.write_json_file(path, tbl)
	return util.write_file(path, util.encode_json(tbl))
end

--- Размер папки в байтах + число файлов. Осторожно: рекурсивный обход.
function util.dir_stats(path)
	if not path or not fs.exists(path) then
		return 0, 0
	end
	local entries = fs.list_recursive(path)
	if not entries then
		return 0, 0
	end
	local bytes, files = 0, 0
	for _, e in pairs(entries) do
		if e.is_file then
			files = files + 1
			bytes = bytes + (tonumber(e.size) or 0)
		end
	end
	return bytes, files
end

function util.fmt_bytes(n)
	n = tonumber(n) or 0
	local units = { "Б", "КБ", "МБ", "ГБ", "ТБ" }
	local i = 1
	while n >= 1024 and i < #units do
		n = n / 1024
		i = i + 1
	end
	return string.format("%.1f %s", n, units[i])
end

return util
