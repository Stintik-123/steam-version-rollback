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
local util = require("util")

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
