--- Всё, что связано с локальным Steam: библиотеки, appmanifest (ACF), папки депо.

local fs = require("fs")
local utils = require("utils")
local millennium = require("millennium")
local vdf = require("vdf")
local util = require("util")

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
