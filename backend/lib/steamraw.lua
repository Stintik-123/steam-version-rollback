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
local util = require("util")

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
