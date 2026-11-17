-- СГЕНЕРИРОВАНО tools/bundle-backend.mjs — не редактировать вручную.
-- Правки вносить в backend/lib/*.lua, backend/rpc.lua, backend/patches.lua, backend/boot.lua.

local function __write_marker(name, text)
	-- Всё в pcall: в VM может не быть ни io, ни os.getenv.
	pcall(function()
		local dir = os.getenv("TEMP") or os.getenv("TMP") or "."
		local f = io.open(dir .. "/" .. name, "w")
		if f then
			f:write(text)
			f:close()
		end
	end)
end

__write_marker("vr-boot-start.txt", "start " .. tostring(os.time()) .. "\n")

local __ok, __result = xpcall(function()
	local __modules = {}

	-- ===== lib/vdf.lua =====
	__modules["vdf"] = (function()
--- Минимальный парсер Valve KeyValues (VDF/ACF).
--- Нужен для steamapps/libraryfolders.vdf и steamapps/appmanifest_<appid>.acf.
--- Чистый Lua без внешних зависимостей (кроме string/table), покрыт тестами.

local vdf = {}

local escapes = { n = "\n", t = "\t", r = "\r", ["\\"] = "\\", ['"'] = '"' }

local function skip_ws(s, i)
	local n = #s
	while i <= n do
		local c = s:sub(i, i)
		if c == " " or c == "\t" or c == "\r" or c == "\n" then
			i = i + 1
		elseif c == "/" and s:sub(i + 1, i + 1) == "/" then
			local j = s:find("\n", i + 2, true)
			i = j and (j + 1) or (n + 1)
		else
			break
		end
	end
	return i
end

local function read_quoted(s, i)
	local out, n = {}, #s
	i = i + 1
	while i <= n do
		local c = s:sub(i, i)
		if c == "\\" then
			local nx = s:sub(i + 1, i + 1)
			out[#out + 1] = escapes[nx] or nx
			i = i + 2
		elseif c == '"' then
			return table.concat(out), i + 1
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	return nil, "незакрытая кавычка"
end

local function read_token(s, i)
	local c = s:sub(i, i)
	if c == '"' then
		return read_quoted(s, i)
	end
	if c == "{" or c == "}" then
		return c, i + 1
	end
	local j, n = i, #s
	while j <= n do
		local ch = s:sub(j, j)
		if ch == " " or ch == "\t" or ch == "\r" or ch == "\n" or ch == "{" or ch == "}" or ch == '"' then
			break
		end
		j = j + 1
	end
	if j == i then
		return nil, "неожиданный символ на позиции " .. i
	end
	return s:sub(i, j - 1), j
end

local parse_object

local function parse_body(s, i)
	local obj = {}
	while true do
		i = skip_ws(s, i)
		if i > #s then
			return nil, "неожиданный конец файла (нет '}')"
		end
		local key
		key, i = read_token(s, i)
		if key == nil then
			return nil, i
		end
		if key == "}" then
			return obj, i
		end

		i = skip_ws(s, i)
		local val
		val, i = read_token(s, i)
		if val == nil then
			return nil, i
		end

		if val == "{" then
			local child
			child, i = parse_body(s, i)
			if child == nil then
				return nil, i
			end
			obj[key] = child
		else
			obj[key] = val
			-- условные суффиксы вида [$WIN32] пропускаем
			local save = i
			i = skip_ws(s, i)
			local maybe
			maybe, i = read_token(s, i)
			if type(maybe) ~= "string" or maybe:sub(1, 2) ~= "[$" then
				i = save
			end
		end
	end
end

parse_object = parse_body

--- Разобрать VDF-текст.
--- @return table|nil root, string|nil err например { libraryfolders = { ... } }
function vdf.parse(text)
	if type(text) ~= "string" or text == "" then
		return nil, "пустой VDF"
	end
	local i = skip_ws(text, 1)
	local key
	key, i = read_token(text, i)
	if key == nil then
		return nil, i
	end
	i = skip_ws(text, i)
	local brace
	brace, i = read_token(text, i)
	if brace ~= "{" then
		return nil, "ожидалась '{' после ключа " .. tostring(key)
	end
	local body, err = parse_body(text, i)
	if body == nil then
		return nil, err
	end
	return { [key] = body }
end

--- Достать ключ без учёта регистра (Steam пишет и "AppState", и "appstate").
function vdf.get(tbl, key)
	if type(tbl) ~= "table" then
		return nil
	end
	if tbl[key] ~= nil then
		return tbl[key]
	end
	local lower = tostring(key):lower()
	for k, v in pairs(tbl) do
		if tostring(k):lower() == lower then
			return v
		end
	end
	return nil
end

local function escape_str(s)
	s = tostring(s)
	s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\t", "\\t")
	return s
end

local function encode_value(key, value, indent, out)
	local pad = string.rep("\t", indent)
	if type(value) == "table" then
		out[#out + 1] = pad .. '"' .. escape_str(key) .. '"\n' .. pad .. "{\n"
		for k, v in pairs(value) do
			encode_value(k, v, indent + 1, out)
		end
		out[#out + 1] = pad .. "}\n"
	else
		out[#out + 1] = pad .. '"' .. escape_str(key) .. '"\t\t"' .. escape_str(value) .. '"\n'
	end
end

--- Собрать VDF обратно (пригодится, если решишь править ACF).
function vdf.encode(root)
	local out = {}
	for k, v in pairs(root) do
		encode_value(k, v, 0, out)
	end
	return table.concat(out)
end

return vdf

	end)()

	-- ===== lib/util.lua =====
	__modules["util"] = (function()
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

--- Жёсткий потолок размера ответа RPC.
---
--- Ответ бэкенда идёт во фронтенд через IPC Lua-хоста Millennium. Ответ
--- неограниченного размера (вся база версий, весь лог, сотни сборок) — это
--- переполнение буфера в нативном слое и падение хоста с 0xC0000409.
--- Поэтому: (1) списки режутся У источника, (2) здесь — страховка: если
--- строка всё же превысила лимит, вместо неё уходит понятная заглушка,
--- а не мегабайты в IPC.
util.RPC_MAX_BYTES = 65536

function util.cap_string(text, limit)
	limit = limit or util.RPC_MAX_BYTES
	if type(text) ~= "string" then
		return text, false
	end
	if #text <= limit then
		return text, false
	end
	return text:sub(1, limit), true
end

--- encode_json с предохранителем: превысили лимит — отдаём валидный JSON
--- с пометкой truncated, вместо того чтобы ронять хост огромной строкой.
function util.encode_json_capped(tbl, limit)
	local encoded = util.encode_json(tbl)
	local capped, truncated = util.cap_string(encoded, limit)
	if not truncated then
		return encoded
	end
	util.err("ответ RPC превысил " .. tostring(limit) .. " байт — отправлена заглушка")
	return util.encode_json({
		ok = false,
		truncated = true,
		error = "ответ слишком большой для IPC; сузьте запрос (меньше сборок/записей)",
	})
end

--- Обрезать список сверху, сохранив пометку о обрезке.
function util.cap_list(list, limit)
	limit = limit or 100
	if type(list) ~= "table" then
		return list, false
	end
	local n = 0
	for _ in pairs(list) do
		n = n + 1
	end
	if n <= limit then
		return list, false
	end
	local out = {}
	for i = 1, limit do
		out[i] = list[i]
	end
	return out, true
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

--- Percent-encoding для URL (в Lua нет готового, а UTF-8 надо экранировать).
function util.url_encode(text)
	text = tostring(text or "")
	local out = {}
	for i = 1, #text do
		local byte = text:byte(i)
		local char = text:sub(i, i)
		if
			(byte >= 48 and byte <= 57) -- 0-9
			or (byte >= 65 and byte <= 90) -- A-Z
			or (byte >= 97 and byte <= 122) -- a-z
			or char == "-" or char == "_" or char == "." or char == "~"
		then
			out[#out + 1] = char
		else
			out[#out + 1] = string.format("%%%02X", byte)
		end
	end
	return table.concat(out)
end

--- Дата в UTC. В некоторых сборках LuaVM нет os.date — тогда отдаём timestamp.
function util.date_utc(ts)
	ts = tonumber(ts) or 0
	if ts <= 0 then
		return "?"
	end
	local ok, formatted = pcall(os.date, "!%Y-%m-%d %H:%M UTC", ts)
	if ok and type(formatted) == "string" then
		return formatted
	end
	return tostring(ts)
end

return util

	end)()

	-- ===== lib/steam.lua =====
	__modules["steam"] = (function()
--- Всё, что связано с локальным Steam: библиотеки, appmanifest (ACF), папки депо.

local fs = require("fs")
local utils = require("utils")
local millennium = require("millennium")
local vdf = __modules["vdf"]
local util = __modules["util"]

local steam = {}

function steam.path()
	local ok, p = pcall(millennium.steam_path)
	if ok and type(p) == "string" and p ~= "" then
		return p
	end
	return nil
end

--- Похоже ли значение на путь к папке.
--- В libraryfolders.vdf рядом с папками лежат посторонние строки
--- (например contentstatsid = "1234567"), их нельзя принимать за путь.
function steam.looks_like_path(p)
	if type(p) ~= "string" or p == "" then
		return false
	end
	if p:find("[/\\]") then
		return true
	end
	return p:match("^%a:$") ~= nil
end

--- Список библиотек Steam (диски, куда ставятся игры).
function steam.libraries()
	local root = steam.path()
	if not root then
		return {}
	end
	local out, seen = {}, {}
	local function add(p)
		if not p or p == "" then
			return
		end
		local normalized = p:gsub("\\\\", "\\"):gsub("[/\\]+$", "")
		local key = normalized:lower()
		if seen[key] then
			return
		end
		seen[key] = true
		out[#out + 1] = { path = normalized, steamapps = fs.join(normalized, "steamapps") }
	end

	local lf = fs.join(root, "steamapps", "libraryfolders.vdf")
	local raw = util.read_file(lf)
	if raw then
		local parsed = vdf.parse(raw)
		local folders = parsed and (vdf.get(parsed, "libraryfolders") or vdf.get(parsed, "LibraryFolders"))
		if type(folders) == "table" then
			for _, entry in pairs(folders) do
				if type(entry) == "table" then
					add(vdf.get(entry, "path"))
				elseif type(entry) == "string" then
					if steam.looks_like_path(entry) then
						add(entry) -- очень старый формат
					end
				end
			end
		end
	end
	add(root)
	return out
end

--- Разобрать appmanifest_<appid>.acf.
function steam.read_acf(appid)
	local id = util.norm_id(appid)
	if not id then
		return nil
	end
	for _, lib in ipairs(steam.libraries()) do
		local path = fs.join(lib.steamapps, "appmanifest_" .. id .. ".acf")
		local raw = util.read_file(path)
		if raw then
			local parsed, err = vdf.parse(raw)
			if not parsed then
				util.warn("ACF " .. path .. " не разобран: " .. tostring(err))
			else
				local st = vdf.get(parsed, "AppState") or {}
				local installed = {}
				for depotid, v in pairs(vdf.get(st, "InstalledDepots") or {}) do
					local gid
					if type(v) == "table" then
						gid = util.norm_gid(vdf.get(v, "manifest"))
					else
						gid = util.norm_gid(v)
					end
					if gid then
						installed[tostring(depotid)] = gid
					end
				end
				local user = vdf.get(st, "UserConfig") or {}
				local mounted = vdf.get(st, "MountedConfig") or {}
				local installdir = vdf.get(st, "installdir") or ""
				return {
					appid = id,
					name = vdf.get(st, "name"),
					library = lib.path,
					steamapps = lib.steamapps,
					acf_path = path,
					installdir = installdir,
					install_dir = fs.join(lib.steamapps, "common", installdir),
					installed_depots = installed,
					language = vdf.get(user, "language") or vdf.get(mounted, "language") or "english",
					beta_key = vdf.get(user, "BetaKey") or vdf.get(mounted, "BetaKey") or "public",
					buildid = vdf.get(st, "buildid"),
					state_flags = tonumber(vdf.get(st, "StateFlags")) or nil,
					size_on_disk = tonumber(vdf.get(st, "SizeOnDisk")) or 0,
					auto_update_behavior = tonumber(vdf.get(st, "AutoUpdateBehavior")) or 0,
					last_updated = tonumber(vdf.get(st, "LastUpdated")) or 0,
				}
			end
		end
	end
	return nil
end

--- Все установленные игры (по appmanifest во всех библиотеках).
function steam.installed_apps()
	local out, seen = {}, {}
	for _, lib in ipairs(steam.libraries()) do
		local entries = fs.list(lib.steamapps)
		if entries then
			for _, e in pairs(entries) do
				local id = e.name and e.name:match("^appmanifest_(%d+)%.acf$")
				if id and not seen[id] and e.is_file then
					seen[id] = true
					local acf = steam.read_acf(id)
					if acf then
						local count = 0
						for _ in pairs(acf.installed_depots) do
							count = count + 1
						end
						out[#out + 1] = {
							appid = id,
							name = acf.name or ("App " .. id),
							library = acf.library,
							install_dir = acf.install_dir,
							language = acf.language,
							beta_key = acf.beta_key,
							buildid = acf.buildid,
							size_on_disk = acf.size_on_disk,
							depot_count = count,
							last_updated = acf.last_updated,
						}
					end
				end
			end
		end
	end
	table.sort(out, function(a, b)
		return tostring(a.name):lower() < tostring(b.name):lower()
	end)
	return out
end

--- Библиотека с наибольшим свободным местом (нужна, когда игра не установлена).
--- @param need number|nil сколько байт нужно
--- @return table|nil library, number free
function steam.best_library(need)
	local best, best_free = nil, -1
	for _, lib in ipairs(steam.libraries()) do
		local info = fs.space_info(lib.path)
		local free = info and tonumber(info.available) or 0
		if free > best_free then
			best, best_free = lib, free
		end
	end
	if best and need and need > 0 and best_free < need then
		return best, best_free
	end
	return best, best_free
end

--- Куда download_depot складывает файлы.
function steam.content_dir(steamapps, appid, depotid)
	return fs.join(steamapps, "content", "app_" .. tostring(appid), "depot_" .. tostring(depotid))
end

--- Промежуточные папки загрузки Steam (могут быть разные раскладки).
function steam.staging_dirs(steamapps, appid, depotid)
	return {
		fs.join(steamapps, "downloading", tostring(appid), tostring(depotid)),
		fs.join(steamapps, "downloading", tostring(depotid)),
		fs.join(steamapps, "temp", tostring(depotid)),
	}
end

function steam.open_folder(path)
	if not path or not fs.exists(path) then
		return false, "папка не найдена: " .. tostring(path)
	end
	local cmd
	if util.is_windows() then
		cmd = string.format('explorer.exe "%s"', path)
	else
		cmd = string.format('xdg-open "%s"', path)
	end
	local _, status = utils.exec(cmd)
	return true, tostring(status)
end

return steam

	end)()

	-- ===== lib/appinfo.lua =====
	__modules["appinfo"] = (function()
--- Данные о депо/ветках игры.
--- Источник: публичный api.steamcmd.net (то же app_info, что видит Steam-клиент).
--- Оттуда берём список депо, их ОС/язык/DLC-признаки и GID манифестов по веткам.
--- Приватные (закрытые паролем) ветки там не видны — это ожидаемо.

local http = require("http")
local fs = require("fs")
local util = __modules["util"]

local appinfo = {}

appinfo.API = "https://api.steamcmd.net/v1/info/"
appinfo.TTL = 6 * 3600 -- кэш на 6 часов
appinfo.UA = "VersionRollback/0.1 (Millennium plugin)"

--- Чистая функция: сырой JSON -> нормализованная структура. Покрыта тестом.
function appinfo.normalize(raw, appid)
	local id = tostring(appid)
	local data = type(raw) == "table" and raw.data or nil
	local app = data and (data[id] or data[tonumber(id)])
	if type(app) ~= "table" then
		return nil, "нет данных по приложению " .. id
	end

	local depots, branch_set = {}, {}
	for key, d in pairs(app.depots or {}) do
		local depotid = tostring(key)
		if tonumber(depotid) and type(d) == "table" then
			local cfg = d.config or {}
			local manifests = {}
			for branch, m in pairs(d.manifests or {}) do
				if type(m) == "table" then
					local gid = util.norm_gid(m.gid)
					if gid then
						manifests[branch] = {
							gid = gid,
							size = tonumber(m.size) or 0,
							download = tonumber(m.download) or 0,
						}
						branch_set[branch] = true
					end
				elseif type(m) == "string" or type(m) == "number" then
					-- старый формат: manifests.public = "<gid>"
					local gid = util.norm_gid(m)
					if gid then
						manifests[branch] = { gid = gid, size = 0, download = 0 }
						branch_set[branch] = true
					end
				end
			end
			depots[depotid] = {
				depotid = depotid,
				oslist = cfg.oslist or "",
				language = cfg.language or "",
				arch = cfg.osarch or "",
				dlcappid = d.dlcappid and tostring(d.dlcappid) or nil,
				optionaldlc = cfg.optionaldlc and tostring(cfg.optionaldlc) or nil,
				lowviolence = cfg.lowviolence and true or false,
				manifests = manifests,
			}
		end
	end

	local branches = {}
	for b in pairs(branch_set) do
		branches[#branches + 1] = b
	end
	table.sort(branches, function(a, b)
		if a == "public" then
			return true
		end
		if b == "public" then
			return false
		end
		return a > b -- свежие версии обычно имеют более «поздние» имена
	end)

	return {
		appid = id,
		name = (app.common and app.common.name) or ("App " .. id),
		installdir = (app.config and app.config.installdir) or nil,
		type = (app.common and app.common.type) or nil,
		depots = depots,
		branches = branches,
		listofdlc = (app.extended and app.extended.listofdlc) or nil,
		fetched_at = util.now(),
	}
end

local function cache_path(appid)
	return fs.join(util.data_dir(), "appinfo_" .. tostring(appid) .. ".json")
end

--- Получить нормализованные данные (кэш -> сеть).
--- @param force boolean|nil игнорировать кэш
function appinfo.get(appid, force)
	local id = util.norm_id(appid)
	if not id then
		return nil, "некорректный AppID"
	end
	local path = cache_path(id)

	if not force then
		local cached = util.read_json_file(path)
		if cached and cached.normalized and (util.now() - (tonumber(cached.normalized.fetched_at) or 0)) < appinfo.TTL then
			return cached.normalized
		end
	end

	local res, err = http.get(appinfo.API .. id, {
		timeout = 25,
		user_agent = appinfo.UA,
		headers = { ["Accept"] = "application/json" },
	})
	if not res then
		local cached = util.read_json_file(path)
		if cached and cached.normalized then
			util.warn("сеть недоступна (" .. tostring(err) .. "), использую кэш по app " .. id)
			return cached.normalized
		end
		return nil, "не удалось получить данные о депо: " .. tostring(err)
	end
	if res.status ~= 200 then
		return nil, "api.steamcmd.net вернул HTTP " .. tostring(res.status)
	end

	local raw = util.decode_json(res.body)
	if not raw then
		return nil, "не удалось разобрать ответ api.steamcmd.net"
	end
	if raw.status and raw.status ~= "success" then
		return nil, "api.steamcmd.net: " .. tostring(raw.status)
	end

	local normalized, nerr = appinfo.normalize(raw, id)
	if not normalized then
		return nil, nerr
	end
	util.write_json_file(path, { normalized = normalized })
	util.log("получены депо по " .. normalized.name .. " (" .. id .. "), веток: " .. #normalized.branches)
	return normalized
end

return appinfo

	end)()

	-- ===== lib/localcache.lua =====
	__modules["localcache"] = (function()
--- Локальная история версий: что Steam уже видел на этом компьютере.
---
--- Зачем: история SteamRaw начинается в сентябре 2026, а глубокая история SteamDB
--- недоступна для автоматического чтения. Но на самой машине остаются следы:
---   - logs/content_log.txt — текстовый журнал установок (AppID/DepotID/ManifestID);
---   - steamapps/depotcache/*.manifest — манифесты, которые Steam уже качал;
---   - appmanifest_<appid>.acf — что установлено прямо сейчас.
--- Их комбинация — единственная история, которой ни у кого больше нет.
---
--- ВАЖНО: только метаданные. Никаких ключей депо и обхода прав — скачивание
--- по-прежнему идёт через Steam и только для того, что есть на аккаунте.

local fs = require("fs")
local util = __modules["util"]
local steam = __modules["steam"]

local localcache = {}

localcache.MAX_LOG_BYTES = 32 * 1024 * 1024 -- больше не читаем: content_log бывает огромным

--- Число после подписи ("AppID 1091500" -> "1091500").
local function label_num(line, ...)
	for i = 1, select("#", ...) do
		local label = select(i, ...)
		local value = line:match(label .. "[%s_]*%d+")
		if value then
			local num = value:match("%d+")
			if num then
				return num
			end
		end
	end
	return nil
end

--- Разобрать content_log.txt.
--- Возвращает список { appid, depotid, gid } — по одной записи на строку.
--- Чистая функция (покрыта тестом), I/O не трогает.
function localcache.parse_content_log(text)
	local out = {}
	if type(text) ~= "string" or text == "" then
		return out
	end
	for line in text:gmatch("[^\r\n]+") do
		local depotid = label_num(line, "DepotID", "Depot ID", "Depot")
		local gid = label_num(line, "ManifestID", "Manifest ID", "Manifest")
		local appid = label_num(line, "AppID", "App ID")
		if depotid and gid then
			out[#out + 1] = {
				appid = appid,
				depotid = util.norm_id(depotid),
				gid = util.norm_gid(gid),
			}
		end
	end
	return out
end

--- Имя файла в depotcache -> depotid и GID.
--- Имена встречаются разные: "<depot>_<manifest>.manifest", "<app>_<depot>_<manifest>.manifest",
--- иногда "<manifest>_manifest" (тогда депо неизвестно — такую запись пропускаем).
--- Чистая функция (покрыта тестом).
function localcache.parse_depotcache_name(name)
	if type(name) ~= "string" then
		return nil, nil
	end
	local nums = {}
	for n in name:gmatch("%d+") do
		nums[#nums + 1] = n
	end
	if #nums >= 3 then
		-- <appid>_<depotid>_<manifestid>
		return util.norm_id(nums[#nums - 1]), util.norm_gid(nums[#nums])
	end
	if #nums == 2 then
		return util.norm_id(nums[1]), util.norm_gid(nums[2])
	end
	return nil, nil
end

--- Разобрать вручную вставленный список депо -> GID (например из SteamDB).
--- Понимает: "1091501 2461377369266892508", "1091501, 2461377...",
--- "DepotID 1091501 ManifestID 2461377369266892508".
--- Чистая функция (покрыта тестом).
--- @return table rows, table problems (строки, которые не разобрались)
function localcache.parse_manifest_text(text)
	local rows, problems = {}, {}
	if type(text) ~= "string" then
		return rows, problems
	end
	for line in text:gmatch("[^\r\n]+") do
		local s = line:gsub("^%s+", ""):gsub("%s+$", "")
		if s ~= "" and not s:match("^#") then
			local depotid = label_num(s, "DepotID", "Depot ID", "Depot")
			local gid = label_num(s, "ManifestID", "Manifest ID", "Manifest")
			if not (depotid and gid) then
				local nums = {}
				for n in s:gmatch("%d+") do
					nums[#nums + 1] = n
				end
				if #nums >= 2 then
					depotid, gid = nums[1], nums[2]
				end
			end
			depotid = util.norm_id(depotid)
			gid = util.norm_gid(gid)
			if depotid and gid then
				rows[#rows + 1] = { depotid = depotid, gid = gid }
			else
				problems[#problems + 1] = s
			end
		end
	end
	return rows, problems
end

--- Собрать всё, что нашлось на диске про приложение.
--- @return table entries { {depotid, gid, source} }
function localcache.scan(appid)
	local id = util.norm_id(appid)
	local entries = {}
	if not id then
		return entries
	end

	-- 1. Журнал установок content_log.txt.
	local root = steam.path()
	if root then
		local logs_dir = fs.join(root, "logs")
		local path = fs.join(logs_dir, "content_log.txt")
		local too_big = false
		local ok, listing = pcall(fs.list, logs_dir)
		if ok and listing then
			for _, entry in ipairs(listing) do
				if (entry.name or "") == "content_log.txt" and (tonumber(entry.size) or 0) > localcache.MAX_LOG_BYTES then
					too_big = true
				end
			end
		end
		if too_big then
			util.warn("content_log.txt больше " .. localcache.MAX_LOG_BYTES .. " байт — пропускаю")
		else
			local text = util.read_file(path)
			if text and #text <= localcache.MAX_LOG_BYTES then
				for _, row in ipairs(localcache.parse_content_log(text)) do
					if row.appid == id and row.depotid and row.gid then
						entries[#entries + 1] = { depotid = row.depotid, gid = row.gid, source = "content_log" }
					end
				end
			end
		end
	end

	-- 2. depotcache: манифесты, которые Steam уже качал в любой библиотеке.
	for _, lib in ipairs(steam.libraries()) do
		local dir = fs.join(lib.steamapps, "depotcache")
		local ok, list = pcall(fs.list, dir)
		for _, entry in ipairs(ok and list or {}) do
			local name = entry.name or ""
			if entry.is_file and name:lower():match("%.manifest$") then
				local depotid, gid = localcache.parse_depotcache_name(name)
				if depotid and gid then
					entries[#entries + 1] = { depotid = depotid, gid = gid, source = "depotcache" }
				end
			end
		end
	end

	-- 3. Что установлено прямо сейчас.
	local acf = steam.read_acf(id)
	if acf then
		for depotid, gid in pairs(acf.installed_depots or {}) do
			entries[#entries + 1] = { depotid = depotid, gid = gid, source = "installed" }
		end
	end

	return entries
end

--- Сгруппировать записи: depotid -> список известных GID (по порядку появления).
function localcache.group(entries)
	local out = {}
	for _, row in ipairs(entries or {}) do
		local depotid, gid = tostring(row.depotid or ""), tostring(row.gid or "")
		if depotid ~= "" and gid ~= "" then
			local list = out[depotid]
			if not list then
				list = {}
				out[depotid] = list
			end
			if not list[gid] then
				list[gid] = true
				list[#list + 1] = gid
			end
		end
	end
	return out
end

--- Готовый ответ для фронтенда: по каждому депо — какие манифесты Steam уже видел.
function localcache.report(appid)
	local id = util.norm_id(appid)
	if not id then
		return { ok = false, error = "некорректный AppID" }
	end
	local entries = localcache.scan(id)
	local grouped = localcache.group(entries)

	local depots = {}
	for depotid, list in pairs(grouped) do
		local gids = {}
		for _, gid in ipairs(list) do
			gids[#gids + 1] = gid
		end
		depots[#depots + 1] = { depotid = depotid, gids = gids }
	end
	table.sort(depots, function(a, b)
		return (tonumber(a.depotid) or 0) < (tonumber(b.depotid) or 0)
	end)

	return {
		ok = true,
		appid = id,
		depots = depots,
		entry_count = #entries,
	}
end

return localcache

	end)()

	-- ===== lib/steamraw.lua =====
	__modules["steamraw"] = (function()
--- История версий из SteamRaw (https://steamraw.com).
---
--- Зачем: Steam и api.steamcmd.net отдают только ТЕКУЩИЕ манифесты веток.
--- SteamRaw хранит изменения AppInfo с сентября 2026 и отдаёт их публичным JSON API
--- без ключа (просят лишь кэш и честный User-Agent).
---
--- Что даёт: список buildid по веткам и историю изменений
--- `depots.<depot>.manifests.<branch>.gid` (old_value -> new_value).
--- Из этого можно восстановить, какие манифесты были у депо на момент сборки.
---
--- Чего не даёт: глубокой истории (у SteamDB она с 2010). Если сборка старше
--- начала сбора SteamRaw, реконструкция неполная — это помечается complete=false.
---
--- ВАЖНО: только метаданные. Никаких ключей депо и обхода прав — скачивание всё
--- равно идёт через Steam и только для того, что есть на аккаунте.

local http = require("http")
local fs = require("fs")
local util = __modules["util"]

local steamraw = {}

steamraw.BASE = "https://steamraw.com/api"
steamraw.TTL = 6 * 3600
steamraw.UA = "VersionRollback/0.1 (Millennium plugin; +https://github.com/Stintik-123/steam-version-rollback)"

local function cache_path(appid, kind)
	return fs.join(util.data_dir(), "steamraw_" .. tostring(appid) .. "_" .. kind .. ".json")
end

local function fetch_json(url, cache_file, force)
	if not force then
		local cached = util.read_json_file(cache_file)
		local age = cached and (util.now() - (tonumber(cached.fetched_at) or 0)) or math.huge
		if cached and cached.data and age < steamraw.TTL then
			return cached.data
		end
	end

	local res, err = http.get(url, {
		timeout = 25,
		user_agent = steamraw.UA,
		headers = { ["Accept"] = "application/json" },
	})
	if not res then
		-- сеть отвалилась — отдаём просроченный кэш, он лучше пустоты
		local cached = util.read_json_file(cache_file)
		if cached and cached.data then
			util.warn("SteamRaw недоступен (" .. tostring(err) .. "), использую кэш")
			return cached.data
		end
		return nil, "SteamRaw: " .. tostring(err)
	end
	if res.status ~= 200 then
		return nil, "SteamRaw вернул HTTP " .. tostring(res.status)
	end

	local data = util.decode_json(res.body)
	if not data then
		return nil, "SteamRaw: не удалось разобрать JSON"
	end
	util.write_json_file(cache_file, { fetched_at = util.now(), data = data })
	return data
end

--- Список сборок приложения: [{ buildid, branch, time_updated }]
function steamraw.builds(appid, force)
	local id = util.norm_id(appid)
	if not id then
		return nil, "некорректный AppID"
	end
	local data, err = fetch_json(steamraw.BASE .. "/app/" .. id .. "/builds", cache_path(id, "builds"), force)
	if not data then
		return nil, err
	end
	local out = {}
	for _, row in ipairs(data) do
		if type(row) == "table" then
			out[#out + 1] = {
				buildid = tostring(row.buildid),
				branch = tostring(row.branch or "public"),
				time_updated = tonumber(row.time_updated) or 0,
				seen_at = tonumber(row.seen_at) or 0,
			}
		end
	end
	return out
end

--- История изменений AppInfo: [{ ts, key, old_value, new_value }]
function steamraw.history(appid, force)
	local id = util.norm_id(appid)
	if not id then
		return nil, "некорректный AppID"
	end
	local data, err = fetch_json(steamraw.BASE .. "/app/" .. id .. "/history", cache_path(id, "history"), force)
	if not data then
		return nil, err
	end
	local out = {}
	for _, row in ipairs(data) do
		if type(row) == "table" and row.key then
			out[#out + 1] = {
				ts = tonumber(row.ts) or 0,
				key = tostring(row.key),
				old_value = row.old_value,
				new_value = row.new_value,
			}
		end
	end
	return out
end

--- Чистая функция: восстановить манифесты на момент каждой сборки.
---
--- @param builds table список из steamraw.builds
--- @param history table список из steamraw.history
--- @param current table { [depotid] = gid } — актуальные манифесты ветки
--- @param branch string ветка
--- @return table [{ buildid, ts, branch, depots = {[depotid]=gid}, complete }]
function steamraw.reconstruct(builds, history, current, branch)
	branch = tostring(branch or "public")

	local changes = {}
	for _, entry in ipairs(history or {}) do
		local depotid, key_branch = tostring(entry.key or ""):match("^depots%.(%d+)%.manifests%.([^.]+)%.gid$")
		if depotid and key_branch == branch then
			changes[#changes + 1] = {
				ts = tonumber(entry.ts) or 0,
				depotid = depotid,
				old = util.norm_gid(entry.old_value),
				new = util.norm_gid(entry.new_value),
			}
		end
	end
	-- от новых к старым: отматываем назад от текущего состояния
	table.sort(changes, function(a, b)
		return a.ts > b.ts
	end)

	local oldest = changes[#changes] and changes[#changes].ts or nil

	local state = {}
	for depotid, gid in pairs(current or {}) do
		state[depotid] = gid
	end

	local relevant = {}
	for _, build in ipairs(builds or {}) do
		if tostring(build.branch) == branch then
			relevant[#relevant + 1] = build
		end
	end
	table.sort(relevant, function(a, b)
		return (tonumber(a.time_updated) or 0) > (tonumber(b.time_updated) or 0)
	end)

	local out, index = {}, 1
	for _, build in ipairs(relevant) do
		local ts = tonumber(build.time_updated) or 0
		while changes[index] and changes[index].ts > ts do
			local change = changes[index]
			state[change.depotid] = change.old
			index = index + 1
		end
		local snapshot = {}
		for depotid, gid in pairs(state) do
			snapshot[depotid] = gid
		end
		out[#out + 1] = {
			buildid = tostring(build.buildid),
			ts = ts,
			branch = branch,
			depots = snapshot,
			-- сборка старше начала истории SteamRaw — возможно, часть депо не восстановлена
			complete = (oldest ~= nil and ts >= oldest) or (next(state) == nil),
		}
	end
	return out
end

--- Собрать список версий для игры и ветки.
--- current — { depotid = gid } из appinfo для этой ветки.
function steamraw.versions(appid, branch, current, force)
	local builds, berr = steamraw.builds(appid, force)
	if not builds then
		return nil, berr
	end
	local history, herr = steamraw.history(appid, force)
	if not history then
		return nil, herr
	end
	return steamraw.reconstruct(builds, history, current, branch)
end

return steamraw

	end)()

	-- ===== lib/steamcounts.lua =====
	__modules["steamcounts"] = (function()
--- SteamCounts (https://steamcounts.info) — второй источник истории версий.
---
--- Что отдаёт: страница игры рендерится на сервере и содержит две таблицы:
---   - Updates: дата наблюдения, ветка, build (старый → новый), сколько депо
---     изменилось, номер changelist;
---   - Depots: текущие депо с размером, ОС и manifest GID.
---
--- Чего не отдаёт: снимок манифестов на момент старой сборки (только текущие
--- GID), поэтому по нему нельзя откатиться к произвольной старой версии —
--- но можно узнать, какие сборки и когда существовали, и перепроверить текущие
--- манифесты, если api.steamcmd.net молчит.
---
--- Честность: публичного API у сайта нет, страница разбирается как есть.
--- Сайт не запрещает это (в отличие от SteamDB), но и не поощряет: запросы
--- делаем редко и с кэшем на 6 часов.
---
--- ВАЖНО: только метаданные. Никаких ключей депо и обхода прав.

local http = require("http")
local fs = require("fs")
local util = __modules["util"]

local steamcounts = {}

steamcounts.BASE = "https://steamcounts.info/app/"
steamcounts.TTL = 6 * 3600
steamcounts.UA = "VersionRollback/0.1 (Millennium plugin; +https://github.com/Stintik-123/steam-version-rollback)"

local function cache_path(appid)
	return fs.join(util.data_dir(), "steamcounts_" .. tostring(appid) .. ".html")
end

--- Текст ячейки без тегов.
local function strip_tags(html)
	local text = html:gsub("<[^>]*>", "")
	text = text:gsub("&[a-zA-Z]+;", " ")
	text = text:gsub("&#[0-9]+;", " ")
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Строки таблицы в виде списка (gmatch отдаёт итератор, а не массив).
local function table_rows(block)
	local out = {}
	for row in block:gmatch("<tr[^>]*>(.-)</tr>") do
		out[#out + 1] = row
	end
	return out
end

--- Разобрать одну строку таблицы: список ячеек { text, val }.
--- @param row string HTML строки <tr ...>...</tr>
--- @return table cells
function steamcounts.parse_row(row)
	local cells = {}
	for attrs, body in row:gmatch("<t[dh]([^>]*)>(.-)</t[dh]>") do
		local val = attrs:match('data%-val="([^"]*)"')
		cells[#cells + 1] = { text = strip_tags(body), val = val }
	end
	return cells
end

--- Вытащить секцию страницы по маркеру id="..." (до следующей секции).
local function section(html, marker)
	local at = html:find(marker, 1, true)
	if not at then
		return ""
	end
	local rest = html:sub(at + 1)
	local stop = rest:find("</table>", 1, true)
	if not stop then
		return rest
	end
	return rest:sub(1, stop)
end

--- Текущие депо: { [depotid] = { gid, size, os } }
--- Чистая функция (покрыта тестом).
function steamcounts.parse_depots(html)
	local out = {}
	local block = section(html, 'id="depots"')
	for _, row in ipairs(table_rows(block)) do
		local cells = steamcounts.parse_row(row)
		if #cells >= 2 then
			local depotid = util.norm_id(cells[1].val or cells[1].text)
			local gid, size, os
			for i = 2, #cells do
				local text = cells[i].text
				local val = cells[i].val
				if gid == nil and text and #text >= 15 and text:match("^%d+$") then
					gid = util.norm_gid(text)
				elseif size == nil and val and val:match("^%d+$")
					and (text:match("GB") or text:match("MB") or text:match("KB") or text:match("TB")) then
					size = math.floor(tonumber(val) or 0)
				elseif os == nil and text and text ~= "" and not text:match("^%d") then
					os = text
				end
			end
			if depotid and gid then
				out[depotid] = { depotid = depotid, gid = gid, size = size or 0, os = os or "" }
			end
		end
	end
	return out
end

--- История обновлений: [{ ts, branch, buildid, prev_buildid, depots_changed, changelist }]
--- Чистая функция (покрыта тестом).
function steamcounts.parse_updates(html)
	local out = {}
	local block = section(html, 'id="updates"')
	for _, row in ipairs(table_rows(block)) do
		local cells = steamcounts.parse_row(row)
		if #cells >= 5 then
			local ts = tonumber(cells[1].val)
			local branch = cells[2].text
			local buildid = util.norm_id(cells[3].val or "")
			-- в ячейке сборки может быть «старый → новый»: старое — первое число,
			-- отличное от data-val (нового buildid)
			local prev = nil
			for num in cells[3].text:gmatch("%d+") do
				if buildid == nil or num ~= buildid then
					prev = util.norm_id(num)
					break
				end
			end
			local changed = tonumber(cells[4].val)
			local changelist = util.norm_id(cells[5].val or "")
			if ts and buildid then
				out[#out + 1] = {
					ts = ts,
					branch = branch or "public",
					buildid = buildid,
					prev_buildid = prev,
					depots_changed = changed or 0,
					changelist = changelist,
				}
			end
		end
	end
	return out
end

--- Забрать страницу игры (с кэшем).
--- @return string|nil html, string|nil err
function steamcounts.fetch(appid, force)
	local id = util.norm_id(appid)
	if not id then
		return nil, "некорректный AppID"
	end
	local file = cache_path(id)
	if not force then
		local cached = util.read_file(file)
		if cached and #cached > 0 then
			local stamp = util.read_json_file(file .. ".meta")
			local age = stamp and (util.now() - (tonumber(stamp.fetched_at) or 0)) or math.huge
			if age < steamcounts.TTL then
				return cached
			end
		end
	end

	local res, err = http.get(steamcounts.BASE .. id, {
		timeout = 20,
		user_agent = steamcounts.UA,
		headers = { ["Accept"] = "text/html" },
	})
	if not res then
		local cached = util.read_file(file)
		if cached and #cached > 0 then
			util.warn("SteamCounts недоступен (" .. tostring(err) .. "), беру кэш")
			return cached
		end
		return nil, "SteamCounts: " .. tostring(err)
	end
	if res.status ~= 200 then
		return nil, "SteamCounts вернул HTTP " .. tostring(res.status)
	end
	if type(res.body) ~= "string" or #res.body == 0 then
		return nil, "SteamCounts: пустая страница"
	end
	util.write_file(file, res.body)
	util.write_json_file(file .. ".meta", { fetched_at = util.now() })
	return res.body
end

--- Собрать всё по игре: депо с GID + история обновлений.
function steamcounts.collect(appid, force)
	local html, err = steamcounts.fetch(appid, force)
	if not html then
		return nil, err
	end
	local depots = steamcounts.parse_depots(html)
	local updates = steamcounts.parse_updates(html)
	local count = 0
	for _ in pairs(depots) do
		count = count + 1
	end
	return {
		depots = depots,
		updates = updates,
		depot_count = count,
	}
end

return steamcounts

	end)()

	-- ===== lib/versiondb.lua =====
	__modules["versiondb"] = (function()
--- Общая база версий: buildid + манифесты депо (depotid -> GID).
---
--- Зачем: история SteamRaw начинается в сентябре 2026, а SteamDB парсить нельзя.
--- Значит, историю нужно копить самим: складывать в базу то, что уже известно
--- (сборки SteamRaw, реконструированные манифесты) и то, что нашлось на
--- компьютерах пользователей (локальный сбор).
---
--- Где живёт база:
---   1) resources/versions-db.json — общая база, едет в .star (собирается
---      скриптом tools/build-versions-db.mjs из SteamRaw + steamcmd.net);
---   2) %LOCALAPPDATA%\VersionRollback\versions-db.json — локальная копия:
---      сюда попадает всё, что собрано на этой машине, и всё, что прислали
---      пользователи. Приоритет у локальной копии.
---
--- Формат:
--- {
---   "version": 1,
---   "updated": 1760000000,
---   "apps": {
---     "1091500": {
---       "name": "Cyberpunk 2077",
---       "builds": { "20000001": { "ts": 1760000000, "branch": "public",
---                                "depots": { "1091501": "3524634124112875626" } } },
---       "manifests": { "1091501:3524634124112875626": { "depotid": "1091501",
---                                "gid": "3524634124112875626", "ts": 1760000000 } }
---     }
---   }
--- }
---
--- ВАЖНО: только метаданные. Никаких ключей депо и обхода прав — скачивание
--- по-прежнему идёт через Steam и только для того, что есть на аккаунте.

local fs = require("fs")
local millennium = require("millennium")
local util = __modules["util"]

local versiondb = {}

versiondb.PACKAGED = "resources/versions-db.json"
versiondb.USER_FILE = "versions-db.json"
versiondb.VERSION = 1

local function empty_db()
	return { version = versiondb.VERSION, updated = 0, apps = {} }
end

local function normalize_db(raw)
	if type(raw) ~= "table" then
		return nil
	end
	if type(raw.apps) ~= "table" then
		raw.apps = {}
	end
	raw.version = raw.version or versiondb.VERSION
	raw.updated = tonumber(raw.updated) or 0
	for _, app in pairs(raw.apps) do
		if type(app) == "table" then
			app.builds = type(app.builds) == "table" and app.builds or {}
			app.manifests = type(app.manifests) == "table" and app.manifests or {}
		end
	end
	return raw
end

--- Общая база из ресурсов плагина (может отсутствовать — не ошибка).
function versiondb.packaged()
	local read = millennium.assets and millennium.assets.read
	if not read then
		return nil
	end
	local ok, raw = pcall(read, versiondb.PACKAGED)
	if not ok or not raw then
		return nil
	end
	return normalize_db(util.decode_json(raw))
end

--- Путь локальной копии базы.
function versiondb.user_path()
	return fs.join(util.data_dir(), versiondb.USER_FILE)
end

--- Локальная копия базы с диска.
function versiondb.user()
	return normalize_db(util.read_json_file(versiondb.user_path()))
end

--- Сохранить локальную копию базы.
function versiondb.save_user(db)
	local normalized = normalize_db(db)
	normalized.updated = util.now()
	return util.write_json_file(versiondb.user_path(), normalized)
end

-- после записи локальной копии кэш неактуален
local _save_user_raw = versiondb.save_user
function versiondb.save_user(db)
	local ok = _save_user_raw(db)
	versiondb.invalidate()
	return ok
end

--- Слить две базы: вторая дополняет первую (по сборкам и манифестам).
--- Чистая функция — покрыта тестом.
function versiondb.merge(base, extra)
	local out = normalize_db(base) or empty_db()
	if type(extra) ~= "table" then
		return out
	end
	for appid, app in pairs(extra.apps or {}) do
		local target = out.apps[appid]
		if type(target) ~= "table" then
			target = { name = app.name, builds = {}, manifests = {} }
			out.apps[appid] = target
		end
		if app.name and not target.name then
			target.name = app.name
		end
		for buildid, build in pairs(app.builds or {}) do
			local tb = target.builds[buildid]
			if type(tb) ~= "table" then
				tb = { ts = 0, branch = "public", depots = {}, complete = build.complete ~= false }
				target.builds[buildid] = tb
			end
			tb.ts = math.max(tonumber(tb.ts) or 0, tonumber(build.ts) or 0)
			if build.branch then
				tb.branch = tostring(build.branch)
			end
			-- «неполная» сборка неполной не перестаёт быть: флаг только ухудшается.
			if build.complete == false then
				tb.complete = false
			end
			for depotid, gid in pairs(build.depots or {}) do
				local norm = util.norm_gid(gid)
				if norm and not tb.depots[depotid] then
					tb.depots[depotid] = norm
				end
			end
		end
		for key, manifest in pairs(app.manifests or {}) do
			if not target.manifests[key] then
				target.manifests[key] = manifest
			end
		end
	end
	out.updated = math.max(tonumber(out.updated) or 0, tonumber(extra.updated) or 0)
	return out
end

--- Полная база: общая (из ресурса) + локальная копия.
function versiondb.load()
	local db = versiondb.packaged() or empty_db()
	return versiondb.merge(db, versiondb.user() or {})
end

--- Кэш загруженной базы на ttl секунд: RPC app_known вызывается при каждом
--- входе на страницу игры, перечитывать файлы каждый раз wasteful и медленно.
local cache = { db = nil, at = 0 }

function versiondb.invalidate()
	cache.db = nil
	cache.at = 0
end

function versiondb.cached(ttl)
	ttl = ttl or 60
	local now = util.now()
	if cache.db == nil or now - cache.at > ttl then
		local ok, db = pcall(versiondb.load)
		if ok and type(db) == "table" then
			cache.db = db
			cache.at = now
		elseif cache.db == nil then
			cache.db = empty_db()
			cache.at = now
		end
	end
	return cache.db
end

--- Сборки приложения из базы: [{ buildid, ts, branch, depots, source = "db" }]
function versiondb.builds(db, appid)
	local id = util.norm_id(appid)
	local out = {}
	local app = id and (db.apps or {})[id]
	if type(app) ~= "table" then
		return out
	end
	for buildid, build in pairs(app.builds or {}) do
		local depots = {}
		for depotid, gid in pairs(build.depots or {}) do
			depots[depotid] = tostring(gid)
		end
		out[#out + 1] = {
			buildid = tostring(buildid),
			ts = tonumber(build.ts) or 0,
			branch = tostring(build.branch or "public"),
			depots = depots,
			source = "db",
			-- complete=false: сборка старше начала истории SteamRaw, снимок манифестов неполный
			complete = build.complete ~= false,
		}
	end
	table.sort(out, function(a, b)
		if a.ts ~= b.ts then
			return a.ts > b.ts
		end
		return a.buildid > b.buildid
	end)
	return out
end

--- Есть ли такой манифест в базе (пул манифестов приложения)?
function versiondb.has_manifest(db, appid, depotid, gid)
	local id = util.norm_id(appid)
	local norm = util.norm_gid(gid)
	if not id or not norm then
		return false
	end
	local app = (db.apps or {})[id]
	if type(app) ~= "table" then
		return false
	end
	local key = tostring(depotid) .. ":" .. norm
	if app.manifests and app.manifests[key] then
		return true
	end
	for _, build in pairs(app.builds or {}) do
		if tostring((build.depots or {})[tostring(depotid)] or "") == norm then
			return true
		end
	end
	return false
end

--- Добавить манифест в пул базы (без сборки).
--- @return boolean true — манифест был новым (добавлен), false — уже был
function versiondb.add_manifest(db, appid, depotid, gid, ts)
	local id = util.norm_id(appid)
	local norm = util.norm_gid(gid)
	if not id or not norm then
		return false
	end
	local app = db.apps[id]
	if type(app) ~= "table" then
		app = { name = nil, builds = {}, manifests = {} }
		db.apps[id] = app
	end
	app.manifests = app.manifests or {}
	app.builds = app.builds or {}
	local key = tostring(depotid) .. ":" .. norm
	if app.manifests[key] then
		return false
	end
	app.manifests[key] = { depotid = tostring(depotid), gid = norm, ts = tonumber(ts) or 0 }
	return true
end

--- Есть ли такая сборка в базе.
function versiondb.has_build(db, appid, buildid)
	local id = util.norm_id(appid)
	if not id or not buildid then
		return false
	end
	local app = (db.apps or {})[id]
	if type(app) ~= "table" then
		return false
	end
	return app.builds and app.builds[tostring(buildid)] ~= nil
end

--- Добавить сборку (снимок манифестов) в базу.
--- @param complete boolean|nil false — снимок неполный (сборка старше истории)
function versiondb.add_build(db, appid, buildid, branch, ts, depots, complete)
	local id = util.norm_id(appid)
	if not id or not buildid then
		return false
	end
	local app = db.apps[id]
	if type(app) ~= "table" then
		app = { name = nil, builds = {}, manifests = {} }
		db.apps[id] = app
	end
	app.builds = app.builds or {}
	app.manifests = app.manifests or {}
	local snapshot = {}
	for depotid, gid in pairs(depots or {}) do
		local norm = util.norm_gid(gid)
		if norm then
			snapshot[tostring(depotid)] = norm
			versiondb.add_manifest(db, id, depotid, norm, ts)
		end
	end
	local existed = app.builds[tostring(buildid)]
	if type(existed) == "table" then
		for depotid, gid in pairs(snapshot) do
			existed.depots = existed.depots or {}
			existed.depots[depotid] = gid
		end
		existed.ts = math.max(tonumber(existed.ts) or 0, tonumber(ts) or 0)
		if complete == false then
			existed.complete = false
		end
	elseif next(snapshot) ~= nil then
		app.builds[tostring(buildid)] = {
			ts = tonumber(ts) or 0,
			branch = tostring(branch or "public"),
			depots = snapshot,
			complete = complete ~= false,
		}
	else
		-- Сборка без единого манифеста для отката бесполезна — не храним.
		return false
	end
	return true
end

--- Сводка по базе для приложения (для UI).
function versiondb.summary(db, appid)
	local id = util.norm_id(appid)
	local app = id and (db.apps or {})[id]
	if type(app) ~= "table" then
		return { ok = true, appid = id, in_db = false, builds = 0, manifests = 0 }
	end
	local manifests, builds = 0, 0
	for _ in pairs(app.manifests or {}) do
		manifests = manifests + 1
	end
	for _ in pairs(app.builds or {}) do
		builds = builds + 1
	end
	return {
		ok = true,
		appid = id,
		in_db = true,
		name = app.name,
		builds = builds,
		manifests = manifests,
	}
end

return versiondb

	end)()

	-- ===== lib/collector.lua =====
	__modules["collector"] = (function()
--- Сбор версий по максимуму: всё, что можно собрать на этой машине.
---
--- Что делает: обходит ВСЕ установленные игры и для каждой складывает в
--- локальную копию базы всё найденное:
---   1) локальные кэши Steam (content_log.txt, depotcache, appmanifest) —
---      манифесты, которые Steam уже видел на этой машине;
---   2) SteamRaw — сборки и восстановленные снимки манифестов по всем веткам;
---   3) SteamCounts — текущие GID по депо (перекрёстная проверка).
---
--- Зачем: SteamRaw начинает историю только с октября 2026, SteamDB парсить
--- нельзя. Поэтому историю приходится копить: из общей базы, из чужих
--- находок и из собственных локальных следов.
---
--- ВАЖНО: только метаданные (AppID, buildid, depotid, GID). Никаких ключей
--- депо, никакого обхода прав. Ничего не уходит наружу само — отчёт
--- пользователь отправляет сам (Issue на GitHub), и только по явному согласию.

local fs = require("fs")
local util = __modules["util"]
local steam = __modules["steam"]
local appinfo = __modules["appinfo"]
local localcache = __modules["localcache"]
local steamraw = __modules["steamraw"]
local steamcounts = __modules["steamcounts"]
local versiondb = __modules["versiondb"]

local collector = {}

collector.REPO = "Stintik-123/steam-version-rollback"

--- Один проход по одной игре.
--- @param db table локальная база (в неё пишем)
--- @param appid string
--- @param force boolean обойти кэш сетевых источников
--- @return table сводка по игре
function collector.collect_app(db, appid, force)
	local id = util.norm_id(appid)
	local row = { appid = id, manifests = 0, builds = 0, errors = {} }
	if not id then
		row.errors[#row.errors + 1] = "некорректный AppID"
		return row
	end

	-- 1. Локальные кэши Steam.
	local ok_local, entries = pcall(localcache.scan, id)
	if ok_local then
		for _, entry in ipairs(entries) do
			if versiondb.add_manifest(db, id, entry.depotid, entry.gid, 0) then
				row.manifests = row.manifests + 1
			end
		end
	end

	-- 2. SteamRaw: сборки и снимки манифестов по каждой ветке.
	local ok_info, info = pcall(appinfo.get, id, false)
	if ok_info and info then
		local branches = info.branches or { "public" }
		for _, branch in ipairs(branches) do
			local current = {}
			for depotid, depot in pairs(info.depots or {}) do
				local manifest = depot.manifests and depot.manifests[branch]
				if manifest and manifest.gid then
					current[depotid] = manifest.gid
				end
			end
			local ok_v, versions = pcall(steamraw.versions, id, branch, current, force == true)
			if ok_v and versions then
				for _, entry in ipairs(versions) do
					if next(entry.depots or {}) ~= nil then
						local existed = versiondb.has_build(db, id, entry.buildid)
						if versiondb.add_build(db, id, entry.buildid, entry.branch, entry.ts, entry.depots, entry.complete) and not existed then
							row.builds = row.builds + 1
						end
					end
				end
			end
		end
	else
		row.errors[#row.errors + 1] = "appinfo недоступен"
	end

	-- 3. SteamCounts: текущие GID по депо.
	local ok_sc, sc = pcall(steamcounts.collect, id, force == true)
	if ok_sc and sc then
		for _, depot in pairs(sc.depots or {}) do
			if versiondb.add_manifest(db, id, depot.depotid, depot.gid, 0) then
				row.manifests = row.manifests + 1
			end
		end
	elseif not ok_sc then
		row.errors[#row.errors + 1] = "SteamCounts: " .. tostring(sc)
	end

	return row
end

--- Собрать по всем установленным играм.
--- @return table сводка { apps = [...], builds = N, manifests = N, errors = N }
function collector.collect_all(force)
	local db = versiondb.user() or { version = versiondb.VERSION, updated = 0, apps = {} }
	local apps = steam.installed_apps() or {}
	local summary = { apps = {}, builds = 0, manifests = 0, errors = 0, total_apps = #apps }

	for _, app in ipairs(apps) do
		local row = collector.collect_app(db, app.appid, force)
		row.name = app.name
		summary.apps[#summary.apps + 1] = row
		summary.builds = summary.builds + row.builds
		summary.manifests = summary.manifests + row.manifests
		summary.errors = summary.errors + #row.errors
	end

	versiondb.save_user(db)
	summary.saved_to = versiondb.user_path()
	return summary
end

--- Отчёт для GitHub Issue: то, что собрано на этой машине (локальная база).
--- Без аргумента — по всем играм локальной базы, с appid — только по одной
--- игре (карточка согласия и ручной сбор в настройках).
--- @param appid_filter string|nil
--- @return string body, table stats
function collector.report(appid_filter)
	local filter = appid_filter and tostring(appid_filter) or nil
	local db = versiondb.user() or { apps = {} }
	local body, stats = {}, { apps = 0, builds = 0, manifests = 0 }
	body[#body + 1] = "Сбор метаданных о версиях Steam (только depotid → manifest GID, без ключей депо)."
	body[#body + 1] = ""
	body[#body + 1] = "Источники: локальные кэши Steam (content_log.txt, depotcache, appmanifest), SteamRaw, SteamCounts."
	body[#body + 1] = "Собрано: " .. util.date_utc(util.now())
	body[#body + 1] = ""

	for appid, app in pairs(db.apps or {}) do
		if filter == nil or tostring(appid) == filter then
			local builds, manifests = {}, {}
			for buildid, build in pairs(app.builds or {}) do
				local depots = {}
				local count = 0
				for depotid, gid in pairs(build.depots or {}) do
					depots[#depots + 1] = { depotid = depotid, gid = gid }
					count = count + 1
				end
				if count > 0 then
					table.sort(depots, function(a, b)
						return (tonumber(a.depotid) or 0) < (tonumber(b.depotid) or 0)
					end)
					builds[#builds + 1] = {
						buildid = buildid,
						branch = build.branch or "public",
						ts = tonumber(build.ts) or 0,
						depots = depots,
					}
				end
			end
			for _, manifest in pairs(app.manifests or {}) do
				manifests[#manifests + 1] = manifest
			end
			if #builds > 0 or #manifests > 0 then
				stats.apps = stats.apps + 1
				table.sort(builds, function(a, b)
					if a.ts ~= b.ts then
						return a.ts > b.ts
					end
					return tostring(a.buildid) > tostring(b.buildid)
				end)
				table.sort(manifests, function(a, b)
					if tostring(a.depotid) ~= tostring(b.depotid) then
						return (tonumber(a.depotid) or 0) < (tonumber(b.depotid) or 0)
					end
					return tostring(a.gid) < tostring(b.gid)
				end)
				body[#body + 1] = "### " .. tostring(app.name or ("App " .. tostring(appid))) .. " (" .. tostring(appid) .. ")"
				for _, build in ipairs(builds) do
					local parts = {}
					for _, depot in ipairs(build.depots) do
						parts[#parts + 1] = depot.depotid .. "=" .. depot.gid
					end
					local date = build.ts > 0 and util.date_utc(build.ts) or "?"
					body[#body + 1] = string.format(
						"- build %s · %s · %s · %s",
						tostring(build.buildid), tostring(build.branch), date, table.concat(parts, " ")
					)
					stats.builds = stats.builds + 1
				end
				stats.manifests = stats.manifests + #manifests
				for _, manifest in ipairs(manifests) do
					body[#body + 1] = string.format(
						"- manifest %s → %s (локальный кэш)",
						tostring(manifest.depotid), tostring(manifest.gid)
					)
				end
				body[#body + 1] = ""
			end
		end
	end

	return table.concat(body, "\n"), stats
end

--- Ссылка на создание Issue с готовым телом.
--- Длинные тела лучше отправлять через API по токену, поэтому здесь режем.
function collector.issue_url(body, title)
	local limit = 3000
	local text = body
	local truncated = false
	if #text > limit then
		text = text:sub(1, limit) .. "\n\n… (тело урезано; полный отчёт — в локальном файле)"
		truncated = true
	end
	local url = string.format(
		"https://github.com/%s/issues/new?title=%s&body=%s",
		collector.REPO,
		util.url_encode(title or "Сбор версий Steam"),
		util.url_encode(text)
	)
	return url, truncated
end

return collector

	end)()

	-- ===== lib/plan.lua =====
	__modules["plan"] = (function()
--- Чистая логика: какие депо и с какими манифестами качать.
--- Никакого I/O — покрыто тестами (tests/test_lua.mjs).

local plan = {}

local function array_from_map_keys(map)
	local out = {}
	for k in pairs(map or {}) do
		out[#out + 1] = tostring(k)
	end
	table.sort(out, function(a, b)
		return (tonumber(a) or 0) < (tonumber(b) or 0)
	end)
	return out
end

local function has_language(list, lang)
	if not list or #list == 0 then
		return true
	end
	for _, l in ipairs(list) do
		if tostring(l):lower() == tostring(lang):lower() then
			return true
		end
	end
	return false
end

local function os_matches(oslist, os)
	if oslist == nil or oslist == "" then
		return true
	end
	return oslist:lower():find(os:lower(), 1, true) ~= nil
end

--- Собрать план загрузки.
--- @param info table нормализованный appinfo
--- @param acf table|nil { installed_depots = {[depotid]=gid}, language = "russian" }
--- @param selection table { branch = "2_31_old" } либо { custom = { {depotid="...", gid="..."} } }
--- @param opts table { os = "windows", include_dlc = false, languages = {"russian","english"} }
function plan.build(info, acf, selection, opts)
	opts = opts or {}
	local os = opts.os or "windows"
	local include_dlc = opts.include_dlc and true or false
	local languages = opts.languages
	local warnings, skipped, depots = {}, {}, {}

	if type(info) ~= "table" or type(info.depots) ~= "table" then
		return { ok = false, error = "нет данных о депо приложения" }
	end

	-- 1. Кандидаты: если игра установлена — берём ровно те депо, что поставил Steam
	--    (это автоматически учитывает ОС, язык озвучки и купленные DLC).
	local candidates, source
	if acf and type(acf.installed_depots) == "table" and next(acf.installed_depots) then
		candidates = array_from_map_keys(acf.installed_depots)
		source = "installed"
	else
		candidates = {}
		source = "appinfo"
		for _, depotid in ipairs(array_from_map_keys(info.depots)) do
			local d = info.depots[depotid]
			local reason
			if not os_matches(d.oslist, os) then
				reason = "другая ОС (" .. tostring(d.oslist) .. ")"
			elseif d.language ~= "" and not has_language(languages or { acf and acf.language or "english" }, d.language) then
				reason = "другой язык (" .. d.language .. ")"
			elseif (d.dlcappid or d.optionaldlc) and not include_dlc then
				reason = "DLC (не включён)"
			elseif d.lowviolence then
				reason = "low violence вариант"
			end
			if reason then
				skipped[#skipped + 1] = { depotid = depotid, reason = reason }
			else
				candidates[#candidates + 1] = depotid
			end
		end
	end

	-- 2. Манифесты
	local custom_map = {}
	if type(selection) == "table" and type(selection.custom) == "table" then
		for _, row in pairs(selection.custom) do
			if type(row) == "table" and row.depotid and row.gid then
				custom_map[tostring(row.depotid)] = tostring(row.gid)
			end
		end
	end
	local branch = selection and selection.branch or nil
	local is_custom = next(custom_map) ~= nil

	if not is_custom and not branch then
		return { ok = false, error = "не выбрана версия (ветка или manifest ID)" }
	end
	if is_custom then
		-- ручной режим: качаем только то, что явно указал пользователь
		candidates = array_from_map_keys(custom_map)
		source = "custom"
	end

	local total_size, total_download = 0, 0
	for _, depotid in ipairs(candidates) do
		local d = info.depots[depotid]
		local gid, size, download, note
		if is_custom then
			gid = custom_map[depotid]
			local m = d and d.manifests or {}
			for _, mm in pairs(m) do
				if mm.gid == gid then
					size, download = mm.size, mm.download
					break
				end
			end
			note = "указан вручную"
		else
			local m = d and d.manifests and d.manifests[branch]
			if m then
				gid, size, download = m.gid, m.size, m.download
			end
		end

		if not gid then
			skipped[#skipped + 1] = {
				depotid = depotid,
				reason = d and ("нет манифеста для ветки «" .. tostring(branch) .. "»") or "депо нет в app_info (возможно, DLC не куплен)",
			}
		else
			local installed_gid = acf and acf.installed_depots and acf.installed_depots[depotid]
			local same = installed_gid ~= nil and tostring(installed_gid) == tostring(gid)
			depots[#depots + 1] = {
				depotid = depotid,
				gid = tostring(gid), -- строка! 64 бита
				size = tonumber(size) or 0,
				download = tonumber(download) or 0,
				language = d and d.language or "",
				dlcappid = d and d.dlcappid or nil,
				same_as_installed = same,
				note = note,
			}
			total_size = total_size + (tonumber(size) or 0)
			total_download = total_download + (tonumber(download) or 0)
		end
	end

	if #depots == 0 then
		return {
			ok = false,
			error = "ни одного депо для этой версии не найдено",
			skipped = skipped,
			warnings = warnings,
		}
	end

	if total_download == 0 then
		warnings[#warnings + 1] = "размер загрузки неизвестен — прогресс будет приблизительным"
	end
	if source == "appinfo" then
		warnings[#warnings + 1] = "игра не установлена: набор депо подобран по ОС/языку, проверь список вручную"
	end
	for _, d in ipairs(depots) do
		if d.same_as_installed then
			warnings[#warnings + 1] = "депо " .. d.depotid .. " уже на этом манифесте — Steam просто проверит файлы"
		end
	end

	return {
		ok = true,
		appid = info.appid,
		app_name = info.name,
		branch = branch,
		label = is_custom and "свой манифест" or tostring(branch),
		source = source,
		depots = depots,
		skipped = skipped,
		warnings = warnings,
		total_size = total_size,
		total_download = total_download,
	}
end

return plan

	end)()

	-- ===== lib/jobs.lua =====
	__modules["jobs"] = (function()
--- Очередь загрузок депо.
---
--- Как это работает:
---   * сам Steam качает депо командой консоли download_depot;
---   * команду нельзя выполнить из Lua — она живёт в JS-контексте клиента,
---     поэтому бэкенд просит фронтенд вызвать SteamClient.Console.ExecCommand;
---   * прогресс считаем по размеру файлов на диске (Steam не отдаёт его наружу);
---   * очередь двигает фронтенд своим таймером через tick() — так бэкенд
---     никогда не блокируется ожиданием (никаких sleep в RPC).

local fs = require("fs")
local millennium = require("millennium")
local util = __modules["util"]
local steam = __modules["steam"]

local jobs = {}

local S = {
	batch = nil,
	queue = {},
	active = nil,
	done = {},
	failed = {},
}

local READY_RATIO = 0.995 -- считаем готовым при 99.5% ожидаемого размера
local STABLE_SEC = 25 -- или если размер не растёт столько секунд
local ZERO_TIMEOUT = 300 -- 5 минут без единого байта -> ошибка

local function exec_console(command)
	local ok, res = pcall(millennium.call_frontend_method, "execConsole", { command })
	if not ok then
		return false, tostring(res)
	end
	if res == nil then
		return false, "фронтенд не ответил (Steam UI ещё не загружен?)"
	end
	if res == false then
		return false, "SteamClient.Console.ExecCommand недоступен в этом клиенте"
	end
	return true
end

local function measure(steamapps, appid, depotid)
	local content = steam.content_dir(steamapps, appid, depotid)
	local bytes = util.dir_stats(content)
	local staging = 0
	for _, dir in ipairs(steam.staging_dirs(steamapps, appid, depotid)) do
		staging = staging + (util.dir_stats(dir))
	end
	return bytes, staging, content
end

local function start_row(row)
	local b = S.batch
	local command = string.format("download_depot %s %s %s", b.appid, row.depotid, row.gid)
	local bytes, staging, content = measure(b.steamapps, b.appid, row.depotid)
	local ok, err = exec_console(command)
	if not ok then
		row.status = "failed"
		row.error = err
		S.failed[#S.failed + 1] = row
		util.err("депо " .. row.depotid .. ": " .. tostring(err))
		return
	end
	row.status = "downloading"
	row.started = util.now()
	row.content_dir = content
	row.bytes = bytes
	row.staging = staging
	row.last_change = util.now()
	row.expected = tonumber(row.size) or 0
	S.active = row
	util.log("→ " .. command .. "  (ожидаем " .. util.fmt_bytes(row.expected) .. ")")
end

--- Запустить новую пачку загрузок по плану.
function jobs.start(p, acf, mode)
	if S.active then
		return nil, "уже идёт загрузка депо " .. tostring(S.active.depotid) .. " — дождись или отмени"
	end
	if not acf then
		return nil, "игра не установлена в этой библиотеке: не знаю, куда качать"
	end
	S.batch = {
		id = util.now(),
		appid = p.appid,
		app_name = p.app_name,
		label = p.label,
		branch = p.branch,
		mode = mode or "download",
		library = acf.library,
		steamapps = acf.steamapps,
		install_dir = acf.install_dir,
		installdir = acf.installdir,
		created = util.now(),
		total_download = p.total_download,
		total_size = p.total_size,
		depot_count = #p.depots,
	}
	S.queue, S.done, S.failed = {}, {}, {}
	for _, row in ipairs(p.depots) do
		S.queue[#S.queue + 1] = {
			depotid = row.depotid,
			gid = row.gid,
			size = row.size,
			download = row.download,
			language = row.language,
			same_as_installed = row.same_as_installed,
			status = "queued",
		}
	end
	util.log(string.format("пачка #%s: %s — %s, депо: %d, режим: %s",
		tostring(S.batch.id), tostring(p.app_name), tostring(p.label), #S.queue, S.batch.mode))
	return jobs.tick()
end

--- Двинуть очередь и померить прогресс. Вызывается фронтендом раз в ~2 сек.
function jobs.tick()
	local b = S.batch
	if not b then
		return jobs.snapshot()
	end

	local row = S.active
	if row then
		local bytes, staging, content = measure(b.steamapps, b.appid, row.depotid)
		local now = util.now()
		if bytes ~= row.bytes then
			row.last_change = now
		end
		row.bytes, row.staging, row.content_dir = bytes, staging, content
		local expected = row.expected
		local elapsed = now - (row.started or now)
		local idle = now - (row.last_change or now)

		local ready = false
		if expected > 0 and bytes >= expected * READY_RATIO then
			ready = true
		elseif bytes > 0 and staging == 0 and idle >= STABLE_SEC then
			ready = true
		end

		if ready then
			row.status = "ready"
			row.finished = now
			S.done[#S.done + 1] = row
			S.active = nil
			util.log(string.format("✓ депо %s готово (%s за %d c)", row.depotid, util.fmt_bytes(bytes), elapsed))
		elseif bytes == 0 and staging == 0 and elapsed >= ZERO_TIMEOUT then
			row.status = "failed"
			row.error = "Steam ничего не скачал за 5 минут. Частые причины: разработчик запретил старые манифесты, депо/DLC не куплен, или нет места на диске."
			row.finished = now
			S.failed[#S.failed + 1] = row
			S.active = nil
			util.err("депо " .. row.depotid .. ": " .. row.error)
		end
	end

	if not S.active and #S.queue > 0 then
		local next_row = table.remove(S.queue, 1)
		start_row(next_row)
	end

	return jobs.snapshot()
end

function jobs.snapshot()
	local b = S.batch
	if not b then
		return { active_batch = false, log = util.log_tail(40) }
	end
	local total_expected, total_bytes = 0, 0
	local rows = {}
	local function add(row)
		total_expected = total_expected + (tonumber(row.size) or 0)
		total_bytes = total_bytes + (tonumber(row.bytes) or (row.status == "ready" and tonumber(row.size) or 0) or 0)
		rows[#rows + 1] = {
			depotid = row.depotid,
			gid = row.gid,
			status = row.status,
			bytes = tonumber(row.bytes) or 0,
			expected = tonumber(row.size) or 0,
			staging = tonumber(row.staging) or 0,
			content_dir = row.content_dir,
			error = row.error,
			language = row.language,
		}
	end
	for _, r in ipairs(S.done) do add(r) end
	for _, r in ipairs(S.failed) do add(r) end
	if S.active then add(S.active) end
	for _, r in ipairs(S.queue) do add(r) end

	local finished = #S.done + #S.failed
	return {
		active_batch = true,
		batch = {
			id = b.id,
			appid = b.appid,
			app_name = b.app_name,
			label = b.label,
			branch = b.branch,
			mode = b.mode,
			library = b.library,
			steamapps = b.steamapps,
			install_dir = b.install_dir,
			content_root = fs.join(b.steamapps, "content", "app_" .. b.appid),
			depot_count = b.depot_count,
			total_download = b.total_download,
			total_size = b.total_size,
		},
		rows = rows,
		done_count = #S.done,
		failed_count = #S.failed,
		queued_count = #S.queue,
		finished_count = finished,
		all_ready = (finished == b.depot_count and #S.failed == 0 and S.active == nil and #S.queue == 0),
		is_running = (S.active ~= nil or #S.queue > 0),
		progress = total_expected > 0 and math.min(1, total_bytes / total_expected) or 0,
		total_bytes = total_bytes,
		total_expected = total_expected,
		log = util.log_tail(40),
	}
end

--- Отменить очередь. ВАЖНО: текущий депо Steam докачает сам —
--- надёжной команды отмены именно download_depot у клиента нет.
function jobs.cancel()
	local dropped = #S.queue
	S.queue = {}
	if S.active then
		S.active.status = "cancelled"
		S.failed[#S.failed + 1] = S.active
		S.active = nil
	end
	util.warn("очередь остановлена (снято депо: " .. dropped .. "); текущая загрузка в Steam может продолжиться")
	return jobs.snapshot()
end

function jobs.reset()
	S.batch, S.queue, S.active, S.done, S.failed = nil, {}, nil, {}, {}
	return jobs.snapshot()
end

--- Ручная отметка «готово» — если эвристика не сработала, а файлы на месте.
function jobs.mark_ready(depotid)
	local row = S.active
	if row and tostring(row.depotid) == tostring(depotid) then
		row.status = "ready"
		row.finished = util.now()
		S.done[#S.done + 1] = row
		S.active = nil
		util.log("депо " .. depotid .. " отмечено готовым вручную")
	end
	return jobs.snapshot()
end

function jobs.ready_depots()
	local out = {}
	for _, r in ipairs(S.done) do
		if r.status == "ready" then
			out[#out + 1] = r
		end
	end
	return out
end

function jobs.current_batch()
	return S.batch
end

return jobs

	end)()

	-- ===== lib/swap.lua =====
	__modules["swap"] = (function()
--- Подмена файлов игры скачанной версией + бэкап и откат назад.
---
--- Принципы безопасности:
---   * НИЧЕГО не удаляется: старая версия просто переименовывается
---     (мгновенно, в пределах одного диска);
---   * файлы депо переносятся (rename), а не копируются — быстро и без лишнего места;
---   * перед подменой игра должна быть закрыта;
---   * Steam при следующем запуске может захотеть обновить игру обратно —
---     это ожидаемо, поэтому есть кнопка «Вернуть как было».

local fs = require("fs")
local millennium = require("millennium")
local util = __modules["util"]
local steam = __modules["steam"]
local jobs = __modules["jobs"]

local swap = {}

local BACKUP_SUFFIX = ".vrbak_"
local AFTER_SUFFIX = ".after_rollback_"
local MARKER = "versionrollback.json"

local function merge_move(src, dst, stats)
	if not fs.exists(src) then
		return false, "нет папки " .. tostring(src)
	end
	if not fs.exists(dst) then
		fs.create_directories(dst)
	end
	local entries = fs.list(src)
	if not entries then
		return false, "не читается " .. tostring(src)
	end
	for _, e in pairs(entries) do
		local from = fs.join(src, e.name)
		local to = fs.join(dst, e.name)
		if e.is_directory then
			local ok, err = merge_move(from, to, stats)
			if not ok then
				return false, err
			end
		else
			if fs.exists(to) then
				fs.remove(to)
			end
			local ok = fs.rename(from, to)
			if not ok then
				-- другой том? копируем и удаляем источник
				local copied = fs.copy(from, to)
				if not copied then
					return false, "не удалось перенести " .. from
				end
				fs.remove(from)
				stats.copied = stats.copied + 1
			end
			stats.files = stats.files + 1
			stats.bytes = stats.bytes + (tonumber(e.size) or 0)
		end
	end
	-- подчищаем опустевшие папки депо (только пустые!)
	if fs.is_empty(src) then
		fs.remove(src)
	end
	return true
end

--- Список бэкапов для игры.
function swap.list_backups(appid)
	local acf = steam.read_acf(appid)
	if not acf then
		return {}
	end
	local out = {}
	local common = fs.join(acf.steamapps, "common")
	local entries = fs.list(common)
	if not entries then
		return out
	end
	local prefix = acf.installdir .. BACKUP_SUFFIX
	for _, e in pairs(entries) do
		if e.is_directory and e.name:sub(1, #prefix) == prefix then
			local marker = util.read_json_file(fs.join(e.path, MARKER)) or {}
			out[#out + 1] = {
				dirname = e.name,
				path = e.path,
				created = marker.created or tonumber(e.name:sub(#prefix + 1)) or 0,
				label = marker.label or "?",
				appid = acf.appid,
				depots = marker.depots or {},
			}
		end
	end
	table.sort(out, function(a, b)
		return (tonumber(a.created) or 0) > (tonumber(b.created) or 0)
	end)
	return out
end

--- Применить скачанную версию: бэкап текущей + перенос файлов депо.
function swap.apply(appid)
	local acf = steam.read_acf(appid)
	if not acf then
		return { ok = false, error = "игра не найдена среди установленных" }
	end
	local batch = jobs.current_batch()
	if not batch or tostring(batch.appid) ~= tostring(acf.appid) then
		return { ok = false, error = "нет активной пачки загрузок для этой игры" }
	end
	local snap = jobs.snapshot()
	if not snap.all_ready then
		return { ok = false, error = "не все депо скачаны — подмена запрещена" }
	end
	if not fs.exists(acf.install_dir) then
		return { ok = false, error = "папка игры не найдена: " .. acf.install_dir }
	end

	local ready = jobs.ready_depots()
	for _, row in ipairs(ready) do
		if not row.content_dir or not fs.exists(row.content_dir) then
			return { ok = false, error = "пропали файлы депо " .. row.depotid }
		end
	end

	local ts = util.now()
	local backup_dir = acf.install_dir .. BACKUP_SUFFIX .. ts
	local ok, err = fs.rename(acf.install_dir, backup_dir)
	if not ok then
		return { ok = false, error = "не удалось сделать бэкап (игра запущена? нет прав?): " .. tostring(err) }
	end
	util.log("бэкап текущей версии: " .. backup_dir)

	local created = fs.create_directories(acf.install_dir)
	if created == nil then
		-- откатываем переименование, чтобы не оставить игру без папки
		fs.rename(backup_dir, acf.install_dir)
		return { ok = false, error = "не удалось создать папку игры заново" }
	end

	local stats = { files = 0, bytes = 0, copied = 0 }
	local depot_meta = {}
	for _, row in ipairs(ready) do
		local moved, merr = merge_move(row.content_dir, acf.install_dir, stats)
		if not moved then
			util.err("перенос депо " .. row.depotid .. " прерван: " .. tostring(merr))
			return {
				ok = false,
				error = "перенос прерван: " .. tostring(merr) .. ". Старая версия лежит в " .. backup_dir,
				backup_dir = backup_dir,
				partial = true,
			}
		end
		depot_meta[#depot_meta + 1] = { depotid = row.depotid, gid = row.gid }
	end

	util.write_json_file(fs.join(backup_dir, MARKER), {
		appid = acf.appid,
		name = acf.name,
		label = batch.label,
		branch = batch.branch,
		created = ts,
		original_install_dir = acf.install_dir,
		depots = depot_meta,
		previous_buildid = acf.buildid,
	})

	util.log(string.format("подмена готова: %d файлов, %s (скопировано через том: %d)",
		stats.files, util.fmt_bytes(stats.bytes), stats.copied))

	return {
		ok = true,
		backup_dir = backup_dir,
		install_dir = acf.install_dir,
		files = stats.files,
		bytes = stats.bytes,
		warnings = {
			"Steam может предложить обновить игру обратно — не запускай обновление, если хочешь остаться на этой версии.",
			"Запускать лучше напрямую .exe из папки игры или в офлайн-режиме Steam.",
			"Сетевые игры/античит могут не пустить на старую версию.",
		},
	}
end

--- Вернуть предыдущую версию из бэкапа.
function swap.restore(appid, dirname)
	local acf = steam.read_acf(appid)
	if not acf then
		return { ok = false, error = "игра не найдена" }
	end
	local backups = swap.list_backups(appid)
	local target
	if dirname then
		for _, b in ipairs(backups) do
			if b.dirname == dirname then
				target = b
			end
		end
	else
		target = backups[1]
	end
	if not target then
		return { ok = false, error = "бэкап не найден" }
	end

	if fs.exists(acf.install_dir) then
		local aside = acf.install_dir .. AFTER_SUFFIX .. util.now()
		local ok, err = fs.rename(acf.install_dir, aside)
		if not ok then
			return { ok = false, error = "не удалось отложить текущую папку игры: " .. tostring(err) }
		end
		util.log("текущая (откаченная) версия отложена в " .. aside)
	end

	local ok, err = fs.rename(target.path, acf.install_dir)
	if not ok then
		return { ok = false, error = "не удалось вернуть бэкап: " .. tostring(err) }
	end
	util.log("версия возвращена из " .. target.dirname)
	return { ok = true, install_dir = acf.install_dir, restored_from = target.path }
end

--- Экспериментально: попросить клиент не спешить с обновлением.
--- Команды консоли существуют, но поведение зависит от версии клиента.
function swap.delay_updates(appid, enable)
	local id = util.norm_id(appid)
	if not id then
		return false
	end
	local cmds = {}
	if enable then
		cmds = {
			"app_delay_update " .. id .. " 31536000",
			"app_set_config " .. id .. " AutoUpdateBehavior 1",
		}
	else
		cmds = {
			"app_delay_update " .. id .. " 0",
			"app_set_config " .. id .. " AutoUpdateBehavior 0",
		}
	end
	for _, c in ipairs(cmds) do
		local ok, res = pcall(millennium.call_frontend_method, "execConsole", { c })
		util.log("консоль: " .. c .. " → " .. tostring(ok and res))
	end
	return true
end

return swap

	end)()

	-- ===== patches.lua =====
	__modules["patches"] = (function()
--- Хуки в интерфейс Steam (свойства игры / диалог установки).
---
--- ПОЧЕМУ ПО УМОЛЧАНИЮ ПУСТО:
--- Millennium патчит JS Steam регулярками (RE2) по содержимому конкретных
--- chunk-файлов. Эти регэкспы зависят от сборки клиента: вслепую написанный
--- патч либо не применится, либо (хуже) зацепит не тот код.
---
--- Порядок работы:
---   1) запусти Steam с -dev (или включи dev-режим Millennium), открой DevTools
---      окна SharedJSContext;
---   2) вставь туда содержимое tools/probe.js — он найдёт кандидатов и напечатает
---      куски кода с якорями;
---   3) пришли мне вывод — я соберу точный find/transforms под твою сборку;
---   4) впиши их ниже и включи в настройках плагина «Хуки в интерфейс Steam».
---
--- Шаблон (пример из официальных доков, для понимания синтаксиса):
---   {
---     find  = [[<RE2-регэксп, "накрывающий" нужный кусок файла>]],
---     file  = [[chunk~[0-9a-f]+\.js]],
---     transforms = {
---       {
---         match   = [[<что именно меняем внутри find>]],
---         replace = [[<на что; \1 — группы из match; #{{self}} — наш фронтенд>]],
---       },
---     },
---   }
---
--- Наши фронтенд-точки входа уже готовы и экспортированы с /** @ffi */:
---   #{{self}}?.propertiesSection  → вкладка/секция в свойствах игры
---   #{{self}}?.installPicker      → блок в диалоге установки

local millennium = require("millennium")
local util = __modules["util"]

local patches = {}

--- Сюда добавляются проверенные патчи (см. docs/HOOKING.md).
local DEFINITIONS = {
	-- {
	--   name = "game-properties-section",
	--   find = [[...]],
	--   file = [[chunk~[0-9a-f]+\.js]],
	--   transforms = {
	--     { match = [[...]], replace = [[...#{{self}}?.propertiesSection...]] },
	--   },
	-- },
}

function patches.get()
	local ok, enabled = pcall(millennium.config.get, "enable_ui_hooks")
	if not ok or enabled ~= true then
		return {}
	end
	local out = {}
	for _, p in ipairs(DEFINITIONS) do
		if p.find and p.transforms then
			out[#out + 1] = { find = p.find, file = p.file, transforms = p.transforms }
			util.log("патч включён: " .. tostring(p.name))
		end
	end
	if #out == 0 then
		util.warn("хуки включены, но патчи ещё не подобраны (backend/patches.lua пуст) — работает только панель в настройках Millennium")
	end
	return out
end

return patches

	end)()

	-- ===== rpc.lua =====
	__modules["rpc"] = (function()
--- RPC-поверхность плагина: то, что фронтенд вызывает как backend.<имя>(...).
---
--- Соглашение: сложные данные ходят JSON-строками (так надёжнее всего между
--- LuaJIT и CEF: не теряются 64-битные GID, пустые таблицы и т.п.).
--- Каждый вызов завёрнут в pcall — ошибка не должна ронять бэкенд.

local millennium = require("millennium")
local fs = require("fs")
local http = require("http")
local util = __modules["util"]
local steam = __modules["steam"]
local appinfo = __modules["appinfo"]
local steamraw = __modules["steamraw"]
local steamcounts = __modules["steamcounts"]
local localcache = __modules["localcache"]
local versiondb = __modules["versiondb"]
local collector = __modules["collector"]
local plan = __modules["plan"]
local jobs = __modules["jobs"]
local swap = __modules["swap"]

local function json_call(fn)
	local ok, res = pcall(fn)
	if not ok then
		util.err("RPC: " .. tostring(res))
		return util.encode_json({ ok = false, error = tostring(res) })
	end
	if type(res) == "string" then
		-- строки приходят уже готовым JSON: режем и их, если вдруг огромные
		local capped, truncated = util.cap_string(res)
		if truncated then
			util.err("RPC: строковый ответ превысил лимит IPC — отправлена заглушка")
			return util.encode_json({ ok = false, truncated = true, error = "ответ слишком большой для IPC" })
		end
		return capped
	end
	return util.encode_json_capped(res or { ok = true })
end

local function cfg_get(key, default)
	local ok, value = pcall(millennium.config.get, key)
	if ok and value ~= nil and value ~= "" then
		return value
	end
	return default
end

--- Согласие пользователя на сбор данных. Три состояния:
--- "yes" — собираем, "no" — не собираем, "" (пусто) — ещё не спрашивали.
local function consent_state()
	local value = cfg_get("collect_consent", "")
	if value == true then
		return "yes"
	end
	if value == false then
		return "no"
	end
	value = tostring(value)
	if value == "yes" or value == "no" then
		return value
	end
	return ""
end

--- Локальный сбор метаданных — только по явному согласию пользователя.
local function local_collect_allowed()
	return consent_state() == "yes"
end

--- Подписи веток: сначала пользовательский файл в data_dir, потом ресурс плагина.
local function labels_table()
	local override = util.read_json_file(fs.join(util.data_dir(), "labels.json"))
	if type(override) == "table" then
		return override
	end
	local read = millennium.assets and millennium.assets.read
	local raw = read and read("resources/labels.json")
	if not raw then
		return {}
	end
	return util.decode_json(raw) or {}
end

local function branch_label(appid, branch, labels)
	local per_app = labels[tostring(appid)] or {}
	if per_app[branch] then
		return per_app[branch]
	end
	local generic = labels._generic or {}
	if generic[branch] then
		return generic[branch]
	end
	if branch == "public" then
		return "Текущая (public)"
	end
	return branch
end

local function options_from(json)
	local opts = util.decode_json(json or "{}") or {}
	local languages = opts.languages
	if type(languages) ~= "table" then
		local csv = cfg_get("languages", "english,russian")
		languages = {}
		for word in tostring(csv):gmatch("[^,%s]+") do
			languages[#languages + 1] = word
		end
	end
	-- Явный false/true из UI важнее сохранённой настройки: opts.include_dlc ~= nil решает.
	local include_dlc
	if opts.include_dlc ~= nil then
		include_dlc = opts.include_dlc == true
	else
		include_dlc = cfg_get("include_dlc", false) == true
	end
	return {
		os = opts.os or (util.is_windows() and "windows" or "linux"),
		include_dlc = include_dlc,
		languages = languages,
	}
end

local function selection_from(json)
	local sel = util.decode_json(json or "{}") or {}
	if type(sel.custom) == "table" then
		local rows = {}
		for _, row in pairs(sel.custom) do
			if type(row) == "table" then
				local depotid = util.norm_id(row.depotid)
				local gid = util.norm_gid(row.gid)
				if depotid and gid then
					rows[#rows + 1] = { depotid = depotid, gid = gid }
				end
			end
		end
		if #rows > 0 then
			return { custom = rows }
		end
	end
	if sel.branch and sel.branch ~= "" then
		return { branch = tostring(sel.branch) }
	end
	return nil
end

---@ffi
---@return string JSON
function ping()
	-- Намеренно без cjson: проверяем, не в нём ли причина падения хоста.
	return '{"ok":true,"probe":"raw"}'
end

---@ffi
---@return string JSON { apps, libraries, config }
function get_state()
	return json_call(function()
		return {
			ok = true,
			steam_path = steam.path(),
			libraries = steam.libraries(),
			apps = steam.installed_apps(),
			config = {
				mode = cfg_get("mode", "download"),
				include_dlc = cfg_get("include_dlc", false),
				languages = cfg_get("languages", "english,russian"),
				delay_updates = cfg_get("delay_updates", false),
				local_collect = local_collect_allowed(),
				collect_consent = consent_state(),
				consent_shown_for = cfg_get("consent_shown_for", ""),
				github_token_set = (cfg_get("github_token", "") ~= ""),
				last_appid = cfg_get("last_appid", ""),
			},
		}
	end)
end

---@ffi
---@param appid string
---@param force boolean
---@return string JSON { info, acf, branches }
function get_app(appid, force)
	return json_call(function()
		local id = util.norm_id(appid)
		if not id then
			return { ok = false, error = "некорректный AppID" }
		end
		local info, err = appinfo.get(id, force == true)
		local acf = steam.read_acf(id)
		if not info then
			return { ok = false, error = err, acf = acf }
		end
		local labels = labels_table()
		local branches = {}
		for _, b in ipairs(info.branches) do
			local count, size, download = 0, 0, 0
			for _, d in pairs(info.depots) do
				local m = d.manifests[b]
				if m then
					count = count + 1
					size = size + m.size
					download = download + m.download
				end
			end
			branches[#branches + 1] = {
				branch = b,
				label = branch_label(id, b, labels),
				depot_count = count,
				total_size = size,
				total_download = download,
				is_current = (acf and acf.beta_key == b) or false,
			}
		end
		pcall(millennium.config.set, "last_appid", id)
		return { ok = true, info = info, acf = acf, branches = branches, backups = swap.list_backups(id) }
	end)
end

---@ffi
---@param text string
---@return string JSON
function debug_note(text)
	return json_call(function()
		local dir = util.data_dir()
		local path = require("fs").join(dir, "frontend-debug.txt")
		local line = util.cap_string(tostring(text), 400)
		local ok = require("utils").append_file(path, tostring(util.now()) .. " " .. line .. "\n")
		return { ok = ok ~= nil, path = path }
	end)
end

---@ffi
---@param appid string
---@param branch string
---@param force boolean
---@return string JSON { versions = [{ buildid, ts, branch, depots, complete, source }] }
function get_versions(appid, branch, force)
	return json_call(function()
		local id = util.norm_id(appid)
		if not id then
			return { ok = false, error = "некорректный AppID" }
		end
		local info, err = appinfo.get(id, false)
		if not info then
			return { ok = false, error = err }
		end
		local b = (branch ~= nil and branch ~= "") and tostring(branch) or "public"
		-- текущие манифесты ветки — точка отсчёта для обратной прокрутки истории
		local current = {}
		for depotid, depot in pairs(info.depots) do
			local manifest = depot.manifests and depot.manifests[b]
			if manifest and manifest.gid then
				current[depotid] = manifest.gid
			end
		end

		-- Сборки из общей+локальной базы (то, что накопили раньше).
		local db = versiondb.load()
		local merged, order = {}, {}
		local function put(entry)
			local existing = merged[entry.buildid]
			if existing then
				for depotid, gid in pairs(entry.depots or {}) do
					if not existing.depots[depotid] then
						existing.depots[depotid] = gid
					end
				end
				existing.ts = math.max(existing.ts or 0, entry.ts or 0)
				existing.source = tostring(existing.source) .. "+" .. tostring(entry.source)
				existing.complete = existing.complete and entry.complete
			else
				merged[entry.buildid] = entry
				order[#order + 1] = entry.buildid
			end
		end

		for _, entry in ipairs(versiondb.builds(db, id)) do
			put(entry)
		end

		local versions, verr = steamraw.versions(id, b, current, force == true)
		if versions then
			for _, entry in ipairs(versions) do
				entry.source = "steamraw"
				put(entry)
			end
		else
			versions = {}
		end

		local out = {}
		for _, buildid in ipairs(order) do
			out[#out + 1] = merged[buildid]
		end
		-- IPC-потолок: сотни сборок в одном ответе роняли хост в 0.5.x
		local capped_out, truncated_list = util.cap_list(out, 120)
		out = capped_out
		table.sort(out, function(a, b2)
			if (a.ts or 0) ~= (b2.ts or 0) then
				return (a.ts or 0) > (b2.ts or 0)
			end
			return tostring(a.buildid) > tostring(b2.buildid)
		end)

		return {
			ok = true,
			appid = id,
			app_name = info.name,
			branch = b,
			versions = out,
			truncated = truncated_list or nil,
			db = versiondb.summary(db, id),
			warning = (not versions) and verr or nil,
		}
	end)
end

--- Состояние согласия на сбор: yes / no / "" и факт, что вопрос уже задавали.
---@ffi
---@return string JSON { consent, asked, shown_for, github_token_set }
function get_consent()
	return json_call(function()
		local consent = consent_state()
		local shown = tostring(cfg_get("consent_shown_for", ""))
		return {
			ok = true,
			consent = consent,
			asked = (consent ~= "") or (shown ~= ""),
			shown_for = shown,
			github_token_set = (cfg_get("github_token", "") ~= ""),
		}
	end)
end

--- Зафиксировать ответ пользователя на вопрос о сборе.
---@ffi
---@param value string "yes" | "no"
---@return string JSON
function set_consent(value)
	return json_call(function()
		local v = tostring(value)
		if v ~= "yes" and v ~= "no" then
			return { ok = false, error = "ожидается yes или no" }
		end
		pcall(millennium.config.set, "collect_consent", v)
		pcall(millennium.config.set, "consent_shown_for", "scope-1")
		util.log("согласие на сбор: " .. v)
		return { ok = true, consent = v }
	end)
end

--- Есть ли игра в общей базе версий. Дёшево: без сети, кэш базы на 60 с.
---@ffi
---@param appid string
---@return string JSON { known, in_db, builds, manifests }
function app_known(appid)
	return json_call(function()
		local id = util.norm_id(appid)
		if not id then
			return { ok = false, error = "некорректный AppID" }
		end
		local summary = versiondb.summary(versiondb.cached(60), id)
		return {
			ok = true,
			appid = id,
			known = summary.in_db == true,
			in_db = summary.in_db,
			builds = summary.builds or 0,
			manifests = summary.manifests or 0,
		}
	end)
end

--- Сбор по одной игре + оформление Issue: с токеном создаётся автоматически,
--- без токена возвращаем предзаполненную ссылку (отправляет пользователь).
---@ffi
---@param appid string
---@return string JSON { number?, url?, truncated?, stats? }
function submit_app_issue(appid)
	return json_call(function()
		if not local_collect_allowed() then
			return { ok = false, error = "сбор не разрешён: сначала ответьте на вопрос в библиотеке" }
		end
		local id = util.norm_id(appid)
		if not id then
			return { ok = false, error = "некорректный AppID" }
		end
		-- убедимся, что по игре что-то собрано (локально, без принудительной сети)
		local db = versiondb.user() or { version = versiondb.VERSION, updated = 0, apps = {} }
		local row = collector.collect_app(db, id, false)
		versiondb.save_user(db)

		local body, stats = collector.report(id)
		if stats.apps == 0 then
			return { ok = false, error = "по игре пока нет метаданных: локальные кэши Steam пусты, повторите после установки/запуска игры" }
		end
		local title = string.format("Версия %s: %s сборок, %s манифестов (локальный сбор)", id, tostring(stats.builds), tostring(stats.manifests))
		local token = tostring(cfg_get("github_token", ""))
		if token ~= "" then
			local payload = util.encode_json({ title = title, body = body, labels = { "version-data" } })
			local headers = {
				["Authorization"] = "Bearer " .. token,
				["Accept"] = "application/vnd.github+json",
				["Content-Type"] = "application/json",
				["User-Agent"] = "VersionRollback/0.6 (Millennium plugin)",
			}
			local ok, res = pcall(function()
				if http.post then
					return http.post("https://api.github.com/repos/" .. collector.REPO .. "/issues", {
						headers = headers,
						body = payload,
						timeout = 25,
					})
				end
				return http.request("https://api.github.com/repos/" .. collector.REPO .. "/issues", {
					method = "POST",
					headers = headers,
					body = payload,
					timeout = 25,
				})
			end)
			if ok and res and (res.status == 201 or res.status == 200) then
				local decoded = util.decode_json(res.body or "")
				util.log("Issue создан: " .. tostring(decoded and decoded.html_url))
				return { ok = true, number = decoded and decoded.number, url = decoded and decoded.html_url, stats = stats, auto = true }
			end
			util.warn("GitHub API не принял Issue: " .. tostring(res and res.status))
			-- падаем в ссылочный путь: пользователь отправит сам
		end
		local url, truncated = collector.issue_url(body, title)
		return { ok = true, url = url, truncated = truncated, stats = stats, auto = false, errors = row.errors }
	end)
end

---@ffi
---@param appid string
---@return string JSON сводка по базе версий
function get_db_summary(appid)
	return json_call(function()
		local db = versiondb.load()
		return versiondb.summary(db, util.norm_id(appid))
	end)
end

--- Собрать локальные находки: что Steam уже видел на этой машине и чего нет в базе.
---@ffi
---@param appid string
---@return string JSON { known = [], missing = [], build = {...} }
function collect_local(appid)
	return json_call(function()
		local id = util.norm_id(appid)
		if not id then
			return { ok = false, error = "некорректный AppID" }
		end
		if not local_collect_allowed() then
			return { ok = false, error = "локальный сбор не включён — разрешите его в блоке «Локальный сбор данных»" }
		end
		local db = versiondb.load()
		local entries = localcache.scan(id)
		local known, missing = {}, {}
		local seen = {}
		for _, entry in ipairs(entries) do
			local key = entry.depotid .. ":" .. entry.gid
			if not seen[key] then
				seen[key] = true
				local row = { depotid = entry.depotid, gid = entry.gid, source = entry.source }
				if versiondb.has_manifest(db, id, entry.depotid, entry.gid) then
					known[#known + 1] = row
				else
					missing[#missing + 1] = row
				end
			end
		end

		-- Установленная сейчас версия — тоже находка: у неё есть buildid.
		local acf = steam.read_acf(id)
		local build = nil
		if acf and acf.buildid and next(acf.installed_depots or {}) ~= nil then
			local depots = {}
			for depotid, gid in pairs(acf.installed_depots) do
				depots[depotid] = gid
			end
			build = {
				buildid = tostring(acf.buildid),
				branch = acf.beta_key or "public",
				ts = acf.last_updated or 0,
				depots = depots,
				in_db = false,
			}
			for _, entry in ipairs(versiondb.builds(db, id)) do
				if entry.buildid == build.buildid then
					build.in_db = true
					break
				end
			end
		end

		return {
			ok = true,
			appid = id,
			known = known,
			missing = missing,
			build = build,
			total = #known + #missing,
		}
	end)
end

--- Сохранить локальные находки в локальную копию базы.
---@ffi
---@param appid string
---@return string JSON
function save_local_db(appid)
	return json_call(function()
		local id = util.norm_id(appid)
		if not id then
			return { ok = false, error = "некорректный AppID" }
		end
		if not local_collect_allowed() then
			return { ok = false, error = "локальный сбор не включён" }
		end
		local db = versiondb.user() or { version = versiondb.VERSION, updated = 0, apps = {} }
		local entries = localcache.scan(id)
		local added = 0
		for _, entry in ipairs(entries) do
			if versiondb.add_manifest(db, id, entry.depotid, entry.gid, 0) then
				added = added + 1
			end
		end
		local acf = steam.read_acf(id)
		if acf and acf.buildid then
			local depots = {}
			for depotid, gid in pairs(acf.installed_depots or {}) do
				depots[depotid] = gid
			end
			if versiondb.add_build(db, id, tostring(acf.buildid), acf.beta_key, acf.last_updated, depots) then
				added = added + 1
			end
		end
		local ok = versiondb.save_user(db)
		return { ok = ok == true, appid = id, added = added, path = versiondb.user_path() }
	end)
end

--- Добавить текущие манифесты SteamCounts в локальный пул базы.
---@ffi
---@param appid string
---@return string JSON
function add_steamcounts_db(appid)
	return json_call(function()
		local id = util.norm_id(appid)
		if not id then
			return { ok = false, error = "некорректный AppID" }
		end
		if not local_collect_allowed() then
			return { ok = false, error = "локальный сбор не включён" }
		end
		local data, err = steamcounts.collect(id, false)
		if not data then
			return { ok = false, error = err }
		end
		local db = versiondb.user() or { version = versiondb.VERSION, updated = 0, apps = {} }
		local added = 0
		for _, row in pairs(data.depots or {}) do
			if versiondb.add_manifest(db, id, row.depotid, row.gid, 0) then
				added = added + 1
			end
		end
		local ok = versiondb.save_user(db)
		return { ok = ok == true, appid = id, added = added, path = versiondb.user_path() }
	end)
end

--- Выгрузить локальные находки в файл (для отправки в репозиторий).
---@ffi
---@param appid string
---@return string JSON { path, count }
function export_local(appid)
	return json_call(function()
		local id = util.norm_id(appid)
		if not id then
			return { ok = false, error = "некорректный AppID" }
		end
		if not local_collect_allowed() then
			return { ok = false, error = "локальный сбор не включён" }
		end
		local db = versiondb.load()
		local entries = localcache.scan(id)
		local missing = {}
		for _, entry in ipairs(entries) do
			if not versiondb.has_manifest(db, id, entry.depotid, entry.gid) then
				missing[#missing + 1] = { depotid = entry.depotid, gid = entry.gid, source = entry.source }
			end
		end
		local report = {
			appid = id,
			collected_at = util.now(),
			source = "local Steam cache (content_log.txt, depotcache, appmanifest)",
			note = "только метаданные: depotid и manifest GID. Ключей депо здесь нет.",
			manifests = missing,
		}
		local acf = steam.read_acf(id)
		if acf and acf.buildid then
			local depots = {}
			for depotid, gid in pairs(acf.installed_depots or {}) do
				depots[depotid] = gid
			end
			report.build = { buildid = tostring(acf.buildid), branch = acf.beta_key, ts = acf.last_updated, depots = depots }
		end
		local path = fs.join(util.data_dir(), "local-versions-" .. id .. ".json")
		local ok = util.write_json_file(path, report)
		return { ok = ok == true, path = path, count = #missing }
	end)
end

---@ffi
---@param appid string
---@param text string
---@return string JSON { rows = [{depotid, gid}], problems = [] }
function import_manifests(appid, text)
	return json_call(function()
		local rows, problems = localcache.parse_manifest_text(text)
		return {
			ok = #problems == 0 or #rows > 0,
			appid = util.norm_id(appid),
			rows = rows,
			problems = problems,
			error = (#rows == 0 and #problems > 0) and "не разобралось ни одной строки" or nil,
		}
	end)
end

---@ffi
---@param appid string
---@return string JSON { depots = [{depotid, gids}], entry_count }
function get_local_cache(appid)
	return json_call(function()
		return localcache.report(appid)
	end)
end

--- Второй источник истории: SteamCounts (депо с GID + датированные обновления).
---@ffi
---@param appid string
---@param force boolean
---@return string JSON { depots = [{depotid, gid, size, os}], updates = [...] }
function get_steamcounts(appid, force)
	return json_call(function()
		local id = util.norm_id(appid)
		if not id then
			return { ok = false, error = "некорректный AppID" }
		end
		local data, err = steamcounts.collect(id, force == true)
		if not data then
			return { ok = false, error = err }
		end
		local depots = {}
		for _, row in pairs(data.depots or {}) do
			depots[#depots + 1] = row
		end
		table.sort(depots, function(a, b)
			return (tonumber(a.depotid) or 0) < (tonumber(b.depotid) or 0)
		end)
		return {
			ok = true,
			appid = id,
			depots = depots,
			updates = data.updates or {},
			source = "steamcounts.info",
		}
	end)
end

--- Живая проверка источников из подборки: что отвечает, что требует ключа.
---@ffi
---@return string JSON { results = [{name, status, kind, note}] }
function probe_sources()
	return json_call(function()
		local sources = {
			{ name = "SteamRaw (api)", url = "https://steamraw.com/api/app/1091500", kind = "json" },
			{ name = "SteamCMD API", url = "https://api.steamcmd.net/v1/info/1091500", kind = "json" },
			{ name = "SteamCounts", url = "https://steamcounts.info/app/1091500", kind = "html" },
			{ name = "SteamDB", url = "https://steamdb.info/app/1091500/depots/", kind = "html" },
			{ name = "HubcapDB", url = "https://hubcapmanifest.com/", kind = "html" },
			{ name = "SMD", url = "https://smd.mcbabel.de", kind = "html" },
			{ name = "opensteamdb-api", url = "https://opensteamdb-api.invalid/api/app/1/info", kind = "json" },
			{ name = "Ryuu Manifests", url = "https://manifest-api.ryuu.space/", kind = "json" },
			{ name = "Open-SteamDB", url = "https://opensteamdb.net/", kind = "html" },
			{ name = "Steam AppDB", url = "https://steamappdb.net/", kind = "html" },
		}
		local results = {}
		for _, source in ipairs(sources) do
			local ok, res = pcall(http.get, source.url, {
				timeout = 8,
				user_agent = "VersionRollback/0.1 (probe)",
				headers = { ["Accept"] = source.kind == "json" and "application/json" or "text/html" },
			})
			local status, kind = 0, "dead"
			if ok and res then
				status = res.status or 0
				local body = res.body or ""
				if status == 401 or status == 403 then
					kind = "need-auth"
				elseif status >= 400 or status == 0 then
					kind = "dead"
				elseif body:find("^%s*[{%[]") then
					kind = "json"
				else
					kind = "html"
				end
			end
			results[#results + 1] = { name = source.name, url = source.url, status = status, kind = kind }
		end
		return { ok = true, results = results }
	end)
end

--- Собрать по одной игре (короткий вызов — чтобы не упереться в таймаут RPC).
---@ffi
---@param appid string
---@param force boolean
---@return string JSON сводка по игре
function collect_app(appid, force)
	return json_call(function()
		if not local_collect_allowed() then
			return { ok = false, error = "сбор не разрешён: сначала согласись в карточке обновления" }
		end
		local id = util.norm_id(appid)
		if not id then
			return { ok = false, error = "некорректный AppID" }
		end
		local db = versiondb.user() or { version = versiondb.VERSION, updated = 0, apps = {} }
		local row = collector.collect_app(db, id, force == true)
		versiondb.save_user(db)
		return {
			ok = true,
			appid = id,
			builds = row.builds,
			manifests = row.manifests,
			errors = row.errors,
		}
	end)
end

--- Собрать по ВСЕМ установленным играм: локальные кэши + SteamRaw + SteamCounts.
---@ffi
---@param force boolean
---@return string JSON сводка
function collect_all(force)
	return json_call(function()
		if not local_collect_allowed() then
			return { ok = false, error = "сбор не разрешён: сначала согласись в карточке обновления" }
		end
		local summary = collector.collect_all(force == true)
		summary.ok = true
		return summary
	end)
end

--- Отчёт о собранном + ссылка на создание Issue на GitHub.
---@ffi
---@return string JSON { body, url, stats }
function get_collection_report()
	return json_call(function()
		if not local_collect_allowed() then
			return { ok = false, error = "сбор не разрешён" }
		end
		local body, stats = collector.report()
		body = util.cap_string(body, 50000)
		local url, truncated = collector.issue_url(body, "Сбор версий Steam: " .. tostring(stats.apps) .. " игр")
		return {
			ok = true,
			body = body,
			url = url,
			truncated = truncated,
			stats = stats,
		}
	end)
end

--- Создать Issue на GitHub через API (нужен личный токен в настройках).
---@ffi
---@return string JSON
function post_github_issue()
	return json_call(function()
		if not local_collect_allowed() then
			return { ok = false, error = "сбор не разрешён" }
		end
		local token = tostring(cfg_get("github_token", ""))
		if token == "" then
			return { ok = false, error = "не задан токен GitHub — используйте кнопку «Открыть Issue»" }
		end
		local body, stats = collector.report()
		local title = "Сбор версий Steam: " .. tostring(stats.apps) .. " игр, " .. tostring(stats.builds) .. " сборок"
		local payload = util.encode_json({
			title = title,
			body = body,
			labels = { "version-data" },
		})
		local url = "https://api.github.com/repos/" .. collector.REPO .. "/issues"
		local headers = {
			["Authorization"] = "Bearer " .. token,
			["Accept"] = "application/vnd.github+json",
			["Content-Type"] = "application/json",
			["User-Agent"] = "VersionRollback/0.3 (Millennium plugin)",
		}
		local ok, res = pcall(function()
			if http.post then
				return http.post(url, { headers = headers, body = payload, timeout = 25 })
			end
			return http.request(url, { method = "POST", headers = headers, body = payload, timeout = 25 })
		end)
		if not ok or not res then
			return { ok = false, error = "GitHub API: " .. tostring(res) }
		end
		if res.status ~= 201 and res.status ~= 200 then
			return { ok = false, error = "GitHub API вернул HTTP " .. tostring(res.status) .. ": " .. tostring(res.body or "") }
		end
		local decoded = util.decode_json(res.body or "")
		return {
			ok = true,
			number = decoded and decoded.number,
			url = decoded and decoded.html_url,
			stats = stats,
		}
	end)
end

--- Сохранить токен GitHub (нужен только для автосоздания Issue).
---@ffi
---@param token string
---@return string JSON
function set_github_token(token)
	return json_call(function()
		local value = tostring(token or ""):gsub("%s", "")
		if value == "" then
			pcall(millennium.config.set, "github_token", "")
			return { ok = true, saved = false }
		end
		pcall(millennium.config.set, "github_token", value)
		return { ok = true, saved = true, hint = "токен сохранён в настройках Millennium" }
	end)
end

---@ffi
---@param appid string
---@return string JSON plan
function get_plan(appid, selection_json, options_json)
	return json_call(function()
		local id = util.norm_id(appid)
		local info, err = appinfo.get(id, false)
		if not info then
			return { ok = false, error = err }
		end
		local sel = selection_from(selection_json)
		if not sel then
			return { ok = false, error = "выбери ветку или укажи manifest ID" }
		end
		local acf = steam.read_acf(id)
		return plan.build(info, acf, sel, options_from(options_json))
	end)
end

---@ffi
---@param appid string
---@param selection_json string
---@param options_json string
---@param mode string "download" | "swap"
---@return string JSON snapshot
function start_download(appid, selection_json, options_json, mode)
	return json_call(function()
		local id = util.norm_id(appid)
		local info, err = appinfo.get(id, false)
		if not info then
			return { ok = false, error = err }
		end
		local sel = selection_from(selection_json)
		if not sel then
			return { ok = false, error = "выбери ветку или укажи manifest ID" }
		end
		local acf = steam.read_acf(id)
		local p = plan.build(info, acf, sel, options_from(options_json))
		if not p.ok then
			return p
		end

		-- Игра может быть не установлена: download_depot работает по лицензии, а не по
		-- наличию файлов. Тогда качаем в библиотеку с максимумом свободного места,
		-- и только в режиме «только скачать» — подменять нечего.
		local final_mode = mode or "download"
		local target = acf
		if not target then
			local lib, free = steam.best_library(p.total_size)
			if not lib then
				return { ok = false, error = "не нашёл ни одной библиотеки Steam (libraryfolders.vdf)" }
			end
			if p.total_size > 0 and tonumber(free) and tonumber(free) < p.total_size then
				return {
					ok = false,
					error = "недостаточно места: нужно ~" .. util.fmt_bytes(p.total_size)
						.. ", свободно " .. util.fmt_bytes(free),
				}
			end
			target = {
				appid = id,
				name = info.name,
				library = lib.path,
				steamapps = lib.steamapps,
				install_dir = nil,
				installdir = nil,
				language = "english",
				beta_key = nil,
				buildid = nil,
			}
			final_mode = "download"
		else
			local space = require("fs").space_info(acf.library)
			if space and p.total_size > 0 and tonumber(space.available) and tonumber(space.available) < p.total_size then
				return {
					ok = false,
					error = "недостаточно места: нужно ~" .. util.fmt_bytes(p.total_size)
						.. ", свободно " .. util.fmt_bytes(space.available),
				}
			end
		end

		pcall(millennium.config.set, "mode", final_mode)
		local snap, serr = jobs.start(p, target, final_mode)
		if not snap then
			return { ok = false, error = serr }
		end
		snap.ok = true
		snap.plan = p
		return snap
	end)
end

---@ffi
---@return string JSON snapshot
function tick()
	return json_call(function()
		local snap = jobs.tick()
		snap.ok = true
		return snap
	end)
end

---@ffi
---@return string JSON
function cancel_download()
	return json_call(function()
		local snap = jobs.cancel()
		snap.ok = true
		return snap
	end)
end

---@ffi
---@return string JSON
function reset_batch()
	return json_call(function()
		local snap = jobs.reset()
		snap.ok = true
		return snap
	end)
end

---@ffi
---@param depotid string
---@return string JSON
function mark_ready(depotid)
	return json_call(function()
		local snap = jobs.mark_ready(tostring(depotid))
		snap.ok = true
		return snap
	end)
end

---@ffi
---@param appid string
---@return string JSON
function apply_swap(appid)
	return json_call(function()
		return swap.apply(util.norm_id(appid))
	end)
end

---@ffi
---@param appid string
---@param dirname string
---@return string JSON
function restore_backup(appid, dirname)
	return json_call(function()
		return swap.restore(util.norm_id(appid), dirname ~= "" and dirname or nil)
	end)
end

---@ffi
---@param appid string
---@return string JSON
function list_backups(appid)
	return json_call(function()
		return { ok = true, backups = swap.list_backups(util.norm_id(appid)) }
	end)
end

---@ffi
---@param appid string
---@param enable boolean
---@return string JSON
function delay_updates(appid, enable)
	return json_call(function()
		swap.delay_updates(util.norm_id(appid), enable == true)
		pcall(millennium.config.set, "delay_updates", enable == true)
		return { ok = true }
	end)
end

---@ffi
---@param path string
---@return string JSON
function open_folder(path)
	return json_call(function()
		local ok, err = steam.open_folder(path)
		return { ok = ok, error = not ok and err or nil }
	end)
end

---@ffi
---@param appid string
---@return string JSON
function open_content_folder(appid)
	return json_call(function()
		local id = util.norm_id(appid)
		local acf = steam.read_acf(id)
		if not acf then
			return { ok = false, error = "игра не установлена" }
		end
		local dir = require("fs").join(acf.steamapps, "content", "app_" .. id)
		local ok, err = steam.open_folder(dir)
		return { ok = ok, path = dir, error = not ok and err or nil }
	end)
end

---@ffi
---@param key string
---@param value string
---@return string JSON
function set_setting(key, value)
	return json_call(function()
		local v = value
		if value == "true" then
			v = true
		elseif value == "false" then
			v = false
		end
		pcall(millennium.config.set, key, v)
		return { ok = true, key = key, value = v }
	end)
end

---@ffi
---@return string JSON
function get_log()
	return json_call(function()
		local rows = util.log_tail(80)
		for _, row in ipairs(rows) do
			row.msg = util.cap_string(tostring(row.msg), 240)
		end
		return { ok = true, log = rows }
	end)
end

util.log("RPC-функции зарегистрированы")

	end)()

	-- ===== boot.lua =====
	return (function()
--- Тело бэкенда Version Rollback (входит в сборку backend/main.lua).
---
--- Здесь обычные require: tools/bundle-backend.mjs подставляет вместо них уже
--- загруженные модули, потому что в упакованном .star require соседних файлов
--- не работает (package.path не содержит папку backend).

local millennium = require("millennium")
local util = __modules["util"]
local _ = __modules["rpc"] -- регистрирует @ffi-функции для фронтенда
local patches = __modules["patches"]

local function on_load()
	-- Ошибка внутри on_load убивает Lua-хост, поэтому ловим её сами и пишем
	-- traceback в TEMP: иначе Millennium просто теряет child-процесс.
	local function marker(name, text)
		pcall(function()
			local dir = os.getenv("TEMP") or os.getenv("TMP") or "."
			local file = io.open(dir .. "/" .. name, "w")
			if file then
				file:write(text)
				file:close()
			end
		end)
	end

	marker("vr-onload-enter.txt", tostring(os.time()))
	local ok, err = xpcall(function()
		util.log("Version Rollback загружен, Millennium " .. tostring(millennium.version()))
		millennium.ready()
	end, debug.traceback)
	marker("vr-onload-done.txt", tostring(os.time()) .. " ok=" .. tostring(ok))
	if ok then
		return
	end
	marker("vr-onload-error.txt", tostring(err))
end

local function on_frontend_loaded()
	util.log("фронтенд Steam загружен — консоль клиента доступна для download_depot")
end

local function on_unload()
	util.log("Version Rollback выгружен")
end

return {
	on_load = on_load,
	on_frontend_loaded = on_frontend_loaded,
	on_unload = on_unload,
	patches = patches.get(),
}

	end)()
end, debug.traceback)

if not __ok then
	__write_marker("vr-boot-error.txt", tostring(__result) .. "\n")
	return {
		on_load = function() end,
		on_unload = function() end,
		patches = {},
	}
end

__write_marker("vr-boot-ok.txt", "loaded " .. tostring(os.time()) .. "\n")
return __result
