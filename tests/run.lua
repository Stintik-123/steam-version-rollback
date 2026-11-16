--- Тесты чистой логики: vdf, plan, appinfo.normalize, util.norm_*.
---
--- Запускаются под fengari (Lua 5.3) из tests/test_lua.mjs: хост Millennium
--- (millennium.luavm64.exe) — это IPC-процесс и произвольные скрипты не
--- исполняет. C-модули Millennium (fs/utils/logger/json) подменяются заглушками:
--- тесты не должны трогать диск, сеть и лог.
---
--- Фикстуры приходят глобальными строками из JS-раннера (io в fengari нет).

install_stubs()

package.path = "backend/lib/?.lua;backend/?.lua;" .. package.path

local vdf = require("vdf")
local plan = require("plan")
local util = require("util")
local appinfo = require("appinfo")
local steam = require("steam")

local passed, failed = 0, {}
local current = "?"

local function check(cond, msg)
	if cond then
		passed = passed + 1
	else
		failed[#failed + 1] = current .. ": " .. msg
	end
end

local function eq(actual, expected, msg)
	check(actual == expected, string.format("%s (получено %s, ожидалось %s)", msg, tostring(actual), tostring(expected)))
end

local function test(name, fn)
	current = name
	local ok, err = pcall(fn)
	if not ok then
		failed[#failed + 1] = name .. ": упал с ошибкой " .. tostring(err)
	end
end

-- ============================ VDF ============================
test("vdf: libraryfolders", function()
	local root = assert(vdf.parse(FIXTURE_LIBRARYFOLDERS))
	local folders = vdf.get(root, "libraryfolders")
	check(type(folders) == "table", "нет узла libraryfolders")
	eq(folders["0"].path, "C:\\Program Files (x86)\\Steam", "путь первой библиотеки")
	eq(folders["1"].path, "D:\\SteamLibrary", "путь второй библиотеки")
	eq(folders["1"].apps["730"], "32000000000", "размер приложения в apps")
	eq(vdf.get(folders, "contentstatsid"), "12345678901234567890", "посторонний ключ рядом с папками")
end)

test("steam: посторонняя строка не считается путём", function()
	check(steam.looks_like_path("C:\\Program Files (x86)\\Steam"), "windows-путь")
	check(steam.looks_like_path("D:\\SteamLibrary"), "путь другого диска")
	check(steam.looks_like_path("/home/user/.local/share/Steam"), "linux-путь")
	check(not steam.looks_like_path("12345678901234567890"), "contentstatsid — не путь")
	check(not steam.looks_like_path(""), "пустая строка — не путь больше")
	check(not steam.looks_like_path(nil), "nil — не путь")
end)

test("vdf: appmanifest", function()
	local root = assert(vdf.parse(FIXTURE_ACF))
	local st = vdf.get(root, "AppState")
	eq(st.name, "Cyberpunk 2077", "имя игры")
	eq(st.buildid, "20000001", "buildid")
	eq(st.installdir, "Cyberpunk 2077", "папка установки")
	eq(st.InstalledDepots["1091501"].manifest, "3524634124112875626", "64-битный manifest остался строкой")
	eq(st.UserConfig.BetaKey, "public", "ветка из UserConfig")
end)

test("vdf: encode -> parse", function()
	local text = vdf.encode({ AppState = { appid = "1091500", InstalledDepots = { ["1091501"] = { manifest = "42" } } } })
	local root = assert(vdf.parse(text))
	eq(vdf.get(root, "AppState").appid, "1091500", "appid после roundtrip")
	eq(vdf.get(root, "AppState").InstalledDepots["1091501"].manifest, "42", "manifest после roundtrip")
end)

-- ============================ util ============================
test("util: norm_id", function()
	eq(util.norm_id("1091500"), "1091500", "обычный AppID")
	eq(util.norm_id(-1), "4294967295", "знаковый int32 из CEF")
	eq(util.norm_id("abc"), nil, "мусор")
end)

test("util: norm_gid не превращает число в string", function()
	eq(util.norm_gid("3524634124112875626"), "3524634124112875626", "строка GID")
	eq(util.norm_gid(" 42 "), "42", "пробелы обрезаны")
	eq(util.norm_gid("12.5"), nil, "дробное — не GID")
	eq(util.norm_gid(1e19), nil, "number с экспонентой отвергнут")
end)

-- ============================ plan ============================
local INFO = {
	appid = "1091500",
	name = "Cyberpunk 2077",
	depots = {
		["1091501"] = {
			depotid = "1091501",
			oslist = "windows",
			language = "",
			manifests = {
				public = { gid = "111", size = 1000, download = 500 },
				legacy = { gid = "999", size = 900, download = 450 },
			},
		},
		["1091503"] = {
			depotid = "1091503",
			oslist = "windows",
			language = "russian",
			manifests = { public = { gid = "222", size = 300, download = 100 } },
		},
		["228988"] = {
			depotid = "228988",
			oslist = "windows",
			language = "",
			dlcappid = "1091502",
			manifests = { public = { gid = "333", size = 50, download = 10 } },
		},
	},
	branches = { "public", "legacy" },
}

test("plan: установленная игра — берём депо из ACF", function()
	local acf = { installed_depots = { ["1091501"] = "111", ["1091503"] = "222" }, language = "russian" }
	local p = plan.build(INFO, acf, { branch = "legacy" }, { os = "windows" })
	check(p.ok, "план должен собраться: " .. tostring(p.error))
	eq(p.source, "installed", "источник депо")
	eq(#p.depots, 1, "в ветке legacy есть только 1091501")
	eq(p.depots[1].depotid, "1091501", "депо из ACF")
	eq(p.depots[1].gid, "999", "манифест ветки legacy")
	eq(p.depots[1].same_as_installed, false, "манифест отличается от установленного")
	eq(p.total_size, 900, "сумма размеров")
	eq(p.total_download, 450, "сумма загрузки")
	check(#p.skipped == 1 and p.skipped[1].depotid == "1091503", "депо без манифеста ветки пропущено")
end)

test("plan: ветка public у установленной игры", function()
	local acf = { installed_depots = { ["1091501"] = "111" }, language = "russian" }
	local p = plan.build(INFO, acf, { branch = "public" }, {})
	check(p.ok, "план должен собраться")
	eq(p.depots[1].same_as_installed, true, "тот же манифест, что установлен")
end)

test("plan: свой manifest ID", function()
	local acf = { installed_depots = { ["1091501"] = "111" }, language = "russian" }
	local p = plan.build(INFO, acf, { custom = { { depotid = "1091501", gid = "999" } } }, {})
	check(p.ok, "план должен собраться")
	eq(p.source, "custom", "источник — ручной выбор")
	eq(#p.depots, 1, "ровно одно депо")
	eq(p.depots[1].gid, "999", "указанный GID")
	eq(p.depots[1].size, 900, "размер найден по GID")
end)

test("plan: фильтр по ОС/языку/DLC, когда игра не установлена", function()
	local p = plan.build(INFO, nil, { branch = "public" }, { os = "windows", include_dlc = false, languages = { "english" } })
	check(p.ok, "план должен собраться")
	eq(#p.depots, 1, "только базовое депо 1091501")
	eq(p.depots[1].depotid, "1091501", "выбранное депо")
	local reasons = {}
	for _, s in ipairs(p.skipped) do
		reasons[s.depotid] = s.reason
	end
	check(reasons["1091503"] ~= nil, "русское депо пропущено по языку")
	check(reasons["228988"] ~= nil, "DLC пропущено без include_dlc")
end)

test("plan: include_dlc добавляет депо DLC", function()
	local p = plan.build(INFO, nil, { branch = "public" }, { os = "windows", include_dlc = true, languages = { "english" } })
	check(p.ok, "план должен собраться")
	local ids = {}
	for _, d in ipairs(p.depots) do
		ids[d.depotid] = true
	end
	check(ids["228988"] == true, "DLC-депо попало в план")
end)

test("plan: linux-игра не тянет windows-депо", function()
	local p = plan.build(INFO, nil, { branch = "public" }, { os = "linux", languages = {} })
	check(not p.ok, "нечего качать — план не должен быть ok")
	check(tostring(p.error):find("ни одного депо") ~= nil, "понятная ошибка")
end)

test("plan: без выбора версии", function()
	local p = plan.build(INFO, nil, {}, {})
	check(not p.ok, "план не должен собраться")
	check(tostring(p.error):find("не выбрана версия") ~= nil, "сообщение о выборе версии")
end)

-- ============================ appinfo ============================
test("appinfo: normalize", function()
	local raw = {
		data = {
			["1091500"] = {
				common = { name = "Cyberpunk 2077" },
				config = { installdir = "Cyberpunk 2077" },
				depots = {
					["1091501"] = {
						config = { oslist = "windows", language = "english" },
						manifests = {
							public = { gid = "3524634124112875626", size = 66818683782, download = 30000000000 },
							legacy = { gid = "42", size = 100, download = 50 },
						},
					},
					["branches"] = { config = { oslist = "windows" } },
				},
			},
		},
	}
	local info = assert(appinfo.normalize(raw, "1091500"))
	eq(info.name, "Cyberpunk 2077", "имя")
	eq(info.depots["1091501"].manifests.public.gid, "3524634124112875626", "GID строкой")
	eq(info.depots["1091501"].manifests.public.size, 66818683782, "размер числом")
	eq(info.depots["branches"], nil, "нечисловой ключ depots отброшен")
	eq(info.branches[1], "public", "public первым в списке веток")
	local found_legacy = false
	for _, b in ipairs(info.branches) do
		if b == "legacy" then
			found_legacy = true
		end
	end
	check(found_legacy, "ветка legacy в списке")
end)

test("appinfo: normalize на пустом ответе", function()
	local info, err = appinfo.normalize({ data = {} }, "1")
	eq(info, nil, "нет данных — nil")
	check(tostring(err):find("нет данных") ~= nil, "понятная ошибка")
end)

-- ============================ итог ============================
if #failed > 0 then
	error("ПРОВАЛЕНО " .. #failed .. ":\n  " .. table.concat(failed, "\n  "), 0)
end
return "ALL PASSED: " .. passed .. " проверок"
