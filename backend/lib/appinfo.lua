--- Данные о депо/ветках игры.
--- Источник: публичный api.steamcmd.net (то же app_info, что видит Steam-клиент).
--- Оттуда берём список депо, их ОС/язык/DLC-признаки и GID манифестов по веткам.
--- Приватные (закрытые паролем) ветки там не видны — это ожидаемо.

local http = require("http")
local fs = require("fs")
local util = require("util")

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
