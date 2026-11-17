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
local util = require("util")
local steam = require("steam")

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
