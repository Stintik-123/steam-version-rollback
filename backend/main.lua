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
local util = __modules["util"]
local steam = __modules["steam"]
local appinfo = __modules["appinfo"]
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
		return res
	end
	return util.encode_json(res or { ok = true })
end

local function cfg_get(key, default)
	local ok, value = pcall(millennium.config.get, key)
	if ok and value ~= nil and value ~= "" then
		return value
	end
	return default
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
	return json_call(function()
		return {
			ok = true,
			millennium = millennium.version(),
			steam_path = steam.path(),
			windows = util.is_windows(),
			data_dir = util.data_dir(),
		}
	end)
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
---@param appid string
---@param selection_json string
---@param options_json string
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
		return { ok = true, log = util.log_tail(120) }
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
	util.log("Version Rollback загружен, Millennium " .. tostring(millennium.version()))
	millennium.ready()
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
