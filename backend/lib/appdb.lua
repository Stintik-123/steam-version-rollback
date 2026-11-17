--- steam-appdb (https://github.com/Austrum-lab/steam-appdb) — открытая база AppID.
---
--- Что отдаёт: полный список Steam-приложений (игры, выделенные серверы, DLC,
--- программы) с именами. Собран анонимным PICS (протокол без ключа), обновляется
--- каждые 2 часа. Файлы лежат в data/ репозитория как обычный JSON.
---
--- Зачем плагину: по названию игры можно найти её AppID — в том числе для
--- выделенных серверов и программ, которых нет в выдаче Steam Web API.
---
--- Ограничения (честно):
---   - это каталог AppID, а НЕ история версий: buildid/манифестов здесь нет;
---     версии по-прежнему берутся из SteamRaw / api.steamcmd.net / SteamCounts;
---   - all.json (~6 МБ) и applist.json (~3 МБ) — большие. Поэтому качаем только
---     applist.json (подмножество steamcmd-устанавливаемого: game+tool+application)
---     и НЕ декодируем его через cjson: это сотни тысяч записей, которые съедают
---     память Lua-хоста. Вместо этого файл сканируется как текст — по JSON ищем
---     пары "appid"/"name" шаблоном, без построения таблицы.
---
--- ВАЖНО: только метаданные. Никаких ключей депо и обхода прав.

local http = require("http")
local fs = require("fs")
local util = require("util")

local appdb = {}

appdb.BASE = "https://raw.githubusercontent.com/Austrum-lab/steam-appdb/master/data/"
appdb.FILE = "applist.json"
appdb.URL = appdb.BASE .. appdb.FILE
appdb.TTL = 12 * 3600
appdb.UA = "VersionRollback/0.1 (Millennium plugin; +https://github.com/Stintik-123/steam-version-rollback)"
appdb.MAX_RESULTS = 30

local function cache_path()
	return fs.join(util.data_dir(), "steam-appdb-applist.json")
end

--- Скачать/прочитать каталог AppID (с кэшем на сутки).
--- @param force boolean|nil обновить принудительно
--- @return string|nil raw, string|nil err
function appdb.fetch(force)
	local file = cache_path()
	if not force then
		local cached = util.read_file(file)
		if cached and #cached > 0 then
			local stamp = util.read_json_file(file .. ".meta")
			local age = stamp and (util.now() - (tonumber(stamp.fetched_at) or 0)) or math.huge
			if age < appdb.TTL then
				return cached
			end
		end
	end

	local res, err = http.get(appdb.URL, {
		timeout = 90,
		user_agent = appdb.UA,
		headers = { ["Accept"] = "application/json" },
	})
	if not res then
		local cached = util.read_file(file)
		if cached and #cached > 0 then
			util.warn("steam-appdb недоступен (" .. tostring(err) .. "), беру кэш")
			return cached
		end
		return nil, "steam-appdb: " .. tostring(err)
	end
	if res.status ~= 200 then
		return nil, "steam-appdb вернул HTTP " .. tostring(res.status)
	end
	if type(res.body) ~= "string" or #res.body == 0 then
		return nil, "steam-appdb: пустой ответ"
	end
	util.write_file(file, res.body)
	util.write_json_file(file .. ".meta", { fetched_at = util.now() })
	return res.body
end

--- Найти приложения по названию. Чистая функция (без сети) — покрыта тестом.
--- Формат applist.json: {"applist":{"apps":[{"appid":10,"name":"Counter-Strike"},…]}}
--- @param raw string содержимое файла
--- @param query string подстрока поиска (без учёта регистра)
--- @param limit number|nil максимум результатов
--- @return table список { { appid, name } }
function appdb.scan(raw, query, limit)
	local out = {}
	if type(raw) ~= "string" or raw == "" then
		return out
	end
	local q = string.lower(tostring(query or ""))
	if q == "" then
		return out
	end
	limit = limit or appdb.MAX_RESULTS
	local pos = 1
	while #out < limit do
		local s, e, appid, name = raw:find('"appid":(%d+),"name":"([^"]*)"', pos)
		if not s then
			break
		end
		pos = e + 1
		local lower = string.lower(name)
		if string.find(lower, q, 1, true) then
			out[#out + 1] = { appid = appid, name = name }
		end
	end
	return out
end

--- Найти по названию с загрузкой каталога.
--- @return table results, string|nil err
function appdb.search(query, force)
	local q = tostring(query or "")
	if q == "" then
		return {}, "пустой запрос"
	end
	local raw, err = appdb.fetch(force)
	if not raw then
		return {}, err
	end
	return appdb.scan(raw, q, appdb.MAX_RESULTS), nil
end

--- Имя приложения по AppID (поиск по каталогу).
--- @return string|nil name
function appdb.name_of(appid, force)
	local id = util.norm_id(appid)
	if not id then
		return nil
	end
	local raw, err = appdb.fetch(force)
	if not raw then
		util.warn("steam-appdb: " .. tostring(err))
		return nil
	end
	local s, e, name = raw:find('"appid":' .. id .. ',"name":"([^"]*)"')
	if not s then
		return nil
	end
	return name
end

return appdb
