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

-- ============================ SteamRaw ============================
test("steamraw: реконструкция манифестов на момент сборки", function()
	local steamraw = require("steamraw")
	local builds = {
		{ buildid = "1", branch = "public", time_updated = 300 },
		{ buildid = "2", branch = "public", time_updated = 200 },
		{ buildid = "3", branch = "public", time_updated = 100 },
		{ buildid = "9", branch = "2_31_old", time_updated = 250 },
	}
	local history = {
		{ ts = 300, key = "depots.111.manifests.public.gid", old_value = "9", new_value = "10" },
		{ ts = 200, key = "depots.222.manifests.public.gid", old_value = "19", new_value = "20" },
		{ ts = 100, key = "depots.111.manifests.public.gid", old_value = "8", new_value = "9" },
		-- другая ветка не должна влиять
		{ ts = 250, key = "depots.111.manifests.2_31_old.gid", old_value = "777", new_value = "888" },
	}
	local current = { ["111"] = "10", ["222"] = "20" }
	local list = steamraw.reconstruct(builds, history, current, "public")
	eq(#list, 3, "только сборки public")
	eq(list[1].buildid, "1", "свежая сборка первой")
	eq(list[1].depots["111"], "10", "манифест 111 на сборке 300")
	eq(list[1].depots["222"], "20", "манифест 222 на сборке 300")
	eq(list[2].depots["111"], "9", "111 откатился до 9 на сборке 200")
	eq(list[3].depots["222"], "19", "222 откатился до 19 на сборке 100")
	eq(list[3].depots["111"], "9", "111 остался 9 на сборке 100")
	check(list[1].complete and list[3].complete, "все сборки в пределах истории")
end)

test("steamraw: сборка старше истории — неполная", function()
	local steamraw = require("steamraw")
	local builds = { { buildid = "1", branch = "public", time_updated = 50 } }
	local history = { { ts = 300, key = "depots.111.manifests.public.gid", old_value = "9", new_value = "10" } }
	local list = steamraw.reconstruct(builds, history, { ["111"] = "10" }, "public")
	eq(#list, 1, "одна сборка")
	eq(list[1].complete, false, "история не покрывает такую давность")
end)

-- ============================ localcache ============================
test("localcache: разбор content_log.txt", function()
	local localcache = require("localcache")
	local text = table.concat({
		"AppID 1091500 DepotID 1091501 ManifestID 2461377369266892508 3 0",
		"AppID 1091500 DepotID 1091503 ManifestID 2461377369266892509",
		"AppID 440 DepotID 441 ManifestID 111",
		"строка без манифеста",
	}, "\n")
	local rows = localcache.parse_content_log(text)
	eq(#rows, 3, "три записи с манифестами")
	eq(rows[1].appid, "1091500", "appid")
	eq(rows[1].depotid, "1091501", "depotid")
	eq(rows[1].gid, "2461377369266892508", "64-битный GID остался строкой")
	eq(rows[3].appid, "440", "appid второй игры")
	eq(rows[2].depotid, "1091503", "depotid второго депо")
end)

test("localcache: имя файла depotcache", function()
	local localcache = require("localcache")
	local depotid, gid = localcache.parse_depotcache_name("1091501_2461377369266892508.manifest")
	eq(depotid, "1091501", "depotid из двух чисел")
	eq(gid, "2461377369266892508", "gid из двух чисел")
	depotid, gid = localcache.parse_depotcache_name("1091500_1091501_2461377369266892508.manifest")
	eq(depotid, "1091501", "depotid из трёх чисел")
	eq(gid, "2461377369266892508", "gid из трёх чисел")
	depotid, gid = localcache.parse_depotcache_name("2461377369266892508_manifest")
	eq(depotid, nil, "без depotid разбор не даёт")
end)

test("localcache: импорт списка депо -> GID", function()
	local localcache = require("localcache")
	local text = table.concat({
		"1091501 2461377369266892508",
		"1091503, 2461377369266892509",
		"DepotID 1091505 ManifestID 2461377369266892510",
		"# комментарий",
		"совсем мусор",
	}, "\n")
	local rows, problems = localcache.parse_manifest_text(text)
	eq(#rows, 3, "три разобранные строки")
	eq(rows[1].depotid, "1091501", "depotid пробелом")
	eq(rows[1].gid, "2461377369266892508", "gid пробелом")
	eq(rows[2].gid, "2461377369266892509", "gid через запятую")
	eq(rows[3].depotid, "1091505", "depotid из подписей")
	eq(rows[3].gid, "2461377369266892510", "gid из подписей")
	eq(#problems, 1, "одна неразобранная строка")
	eq(problems[1], "совсем мусор", "что именно не разобралось")
end)

test("localcache: группировка манифестов по депо", function()
	local localcache = require("localcache")
	local grouped = localcache.group({
		{ depotid = "1", gid = "10" },
		{ depotid = "1", gid = "11" },
		{ depotid = "1", gid = "10" },
		{ depotid = "2", gid = "20" },
	})
	eq(#grouped["1"], 2, "два уникальных манифеста у депо 1")
	eq(grouped["1"][1], "10", "порядок сохранён")
	eq(#grouped["2"], 1, "у депо 2 один манифест")
end)

-- ============================ SteamCounts ============================
test("steamcounts: таблица депо с текущими GID", function()
	local steamcounts = require("steamcounts")
	local depots = steamcounts.parse_depots(FIXTURE_STEAMCOUNTS)
	eq(depots["1091501"].gid, "3524634124112875626", "64-битный GID депо 1091501")
	eq(depots["1091501"].size, 66818683782, "размер депо в байтах")
	eq(depots["1091501"].os, "windows", "ОС депо")
	eq(depots["1091502"].gid, "4172273210291337333", "GID второго депо")
	eq(depots["228988"], nil, "депо без манифеста не попало")
end)

test("steamcounts: история обновлений с датами и changelist", function()
	local steamcounts = require("steamcounts")
	local updates = steamcounts.parse_updates(FIXTURE_STEAMCOUNTS)
	eq(#updates, 3, "три обновления")
	eq(updates[1].ts, 1792762494, "время наблюдения")
	eq(updates[1].branch, "public", "ветка")
	eq(updates[1].buildid, "26161058", "новый buildid")
	eq(updates[1].prev_buildid, "26133166", "предыдущий buildid")
	eq(updates[1].depots_changed, 2, "сколько депо изменилось")
	eq(updates[1].changelist, "40170744", "changelist")
	eq(updates[2].branch, "2_31_old", "legacy-ветка сохранена")
	eq(updates[3].prev_buildid, nil, "у первой записи ветки нет предыдущей сборки")
end)

-- ============================ versiondb ============================
test("versiondb: слияние баз не теряет ни сборки, ни манифесты", function()
	local versiondb = require("versiondb")
	local a = {
		version = 1,
		apps = {
			["1091500"] = {
				name = "Cyberpunk 2077",
				builds = { ["20000001"] = { ts = 300, branch = "public", depots = { ["1091501"] = "111" } } },
				manifests = { ["1091501:111"] = { depotid = "1091501", gid = "111", ts = 300 } },
			},
		},
	}
	local b = {
		version = 1,
		apps = {
			["1091500"] = {
				builds = { ["20000002"] = { ts = 100, branch = "public", depots = { ["1091501"] = "222" } } },
				manifests = { ["1091501:222"] = { depotid = "1091501", gid = "222", ts = 100 } },
			},
			["440"] = { builds = { ["10"] = { ts = 50, branch = "public", depots = { ["441"] = "9" } } } },
		},
	}
	local merged = versiondb.merge(a, b)
	eq(merged.apps["1091500"].builds["20000001"].depots["1091501"], "111", "сборка из первой базы")
	eq(merged.apps["1091500"].builds["20000002"].depots["1091501"], "222", "сборка из второй базы")
	eq(merged.apps["1091500"].manifests["1091501:222"].gid, "222", "манифест второй базы")
	eq(merged.apps["440"].builds["10"].depots["441"], "9", "другое приложение")
	eq(merged.apps["1091500"].name, "Cyberpunk 2077", "имя сохранено")
end)

test("versiondb: добавление сборки и манифеста", function()
	local versiondb = require("versiondb")
	local db = { version = 1, apps = {} }
	versiondb.add_build(db, "1091500", "20000005", "public", 500, { ["1091501"] = "2461377369266892508" })
	eq(db.apps["1091500"].builds["20000005"].depots["1091501"], "2461377369266892508", "64-битный GID в сборке")
	eq(db.apps["1091500"].manifests["1091501:2461377369266892508"].gid, "2461377369266892508", "манифест попал в пул")
	check(versiondb.has_manifest(db, "1091500", "1091501", "2461377369266892508"), "манифест найден в базе")
	check(not versiondb.has_manifest(db, "1091500", "1091501", "999"), "чужой манифест не найден")
	local list = versiondb.builds(db, "1091500")
	eq(#list, 1, "одна сборка")
	eq(list[1].source, "db", "источник — база")
end)

test("versiondb: сборка без манифестов не попадает в базу как полезная", function()
	local versiondb = require("versiondb")
	local db = { version = 1, apps = {} }
	versiondb.add_build(db, "440", "10", "public", 50, {})
	eq(next(versiondb.builds(db, "440")), nil, "пустых сборок нет")
end)

test("versiondb: неполная сборка помечается и не «дочиняется» слиянием", function()
	local versiondb = require("versiondb")
	local db = { version = 1, apps = {} }
	versiondb.add_build(db, "440", "10", "public", 500, { ["441"] = "111" }, false)
	local list = versiondb.builds(db, "440")
	eq(list[1].complete, false, "сборка без полного снимка помечена неполной")
	local merged = versiondb.merge(db, {
		apps = { ["440"] = { builds = { ["10"] = { ts = 600, branch = "public", depots = { ["441"] = "222" }, complete = true } } } },
	})
	eq(merged.apps["440"].builds["10"].complete, false, "полная копия не делает неполную полной")
	eq(merged.apps["440"].builds["10"].depots["441"], "111", "манифест из первой базы не перетирается")
end)

-- ============================ collector / util ============================
test("util: url_encode", function()
	eq(util.url_encode("a b"), "a%20b", "пробел")
	eq(util.url_encode("A-Z_0.9~"), "A-Z_0.9~", "безопасные символы не трогаем")
	eq(util.url_encode("привет"), "%D0%BF%D1%80%D0%B8%D0%B2%D0%B5%D1%82", "кириллица по байтам")
	eq(util.url_encode("a&b=c"), "a%26b%3Dc", "разделители экранируются")
end)

test("util: date_utc не падает без os.date", function()
	local value = util.date_utc(1760000000)
	check(type(value) == "string" and #value > 0, "дата — строка")
	eq(util.date_utc(0), "?", "нулевое время")
end)

test("collector: ссылка на Issue с телом", function()
	local collector = require("collector")
	local url, truncated = collector.issue_url("строка 1\nстрока 2", "Заголовок")
	check(url:find("github.com/Stintik-123/steam-version-rollback/issues/new", 1, true) ~= nil, "репозиторий в ссылке")
	check(url:find("title=", 1, true) ~= nil, "заголовок передан")
	check(url:find("body=", 1, true) ~= nil, "тело передано")
	eq(truncated, false, "короткое тело не режется")
	local long, cut = collector.issue_url(string.rep("x", 9000), "T")
	eq(cut, true, "длинное тело помечается как урезанное")
	check(#long < 9000, "ссылка укорочена")
end)

test("util: потолок размера IPC-ответа", function()
	local small, cut = util.cap_string("привет", 100)
	eq(cut, false, "короткая строка не режется")
	eq(small, "привет", "короткая строка не меняется")
	local big = string.rep("x", util.RPC_MAX_BYTES + 10)
	local capped, cut2 = util.cap_string(big)
	eq(cut2, true, "превышение лимита замечено")
	eq(#capped, util.RPC_MAX_BYTES, "строка обрезана ровно по лимиту")
	local list = {}
	for i = 1, 150 do
		list[i] = i
	end
	local short, cut3 = util.cap_list(list, 120)
	eq(cut3, true, "длинный список замечен")
	eq(#short, 120, "список обрезан до лимита")
	local keep, cut4 = util.cap_list({ 1, 2 }, 120)
	eq(cut4, false, "короткий список не режется")
	eq(#keep, 2, "короткий список не меняется")
end)

test("util: encode_json_capped на обычном ответе", function()
	local encoded = util.encode_json_capped({ ok = true })
	check(type(encoded) == "string" and #encoded > 0, "заглушка энкодера отдаёт строку")
end)

test("versiondb: кэш базы и invalidate", function()
	local versiondb = require("versiondb")
	local db = versiondb.cached(60)
	check(type(db) == "table", "кэш вернул таблицу")
	check(versiondb.cached(60) == db, "в пределах ttl отдаётся тот же объект")
	versiondb.invalidate()
	check(versiondb.cached(60) ~= db, "после invalidate объект новый")
end)

test("collector: отчёт по одной игре не тянет чужие", function()
	local collector = require("collector")
	local versiondb = require("versiondb")
	local fake = {
		apps = {
			["292030"] = {
				name = "Witcher 3",
				builds = { ["1"] = { ts = 100, branch = "public", depots = { ["292031"] = "111" } } },
				manifests = {},
			},
			["1091500"] = {
				name = "Cyberpunk",
				builds = { ["2"] = { ts = 200, branch = "public", depots = { ["1091501"] = "222" } } },
				manifests = {},
			},
		},
	}
	local old_user = versiondb.user
	versiondb.user = function()
		return fake
	end
	local ok, body, stats = pcall(collector.report, "292030")
	versiondb.user = old_user
	check(ok, "отчёт по одной игре не падает: " .. tostring(body))
	eq(stats.apps, 1, "в отчёте одна игра")
	check(type(body) == "string" and body:find("Witcher 3", 1, true) ~= nil, "нужная игра в отчёте")
	check(type(body) == "string" and body:find("Cyberpunk", 1, true) == nil, "чужой игры в отчёте нет")
	check(type(body) == "string" and body:find("292031=111", 1, true) ~= nil, "пара depot→GID на месте")

	versiondb.user = function()
		return fake
	end
	local ok2, all, stats2 = pcall(collector.report)
	versiondb.user = old_user
	check(ok2, "полный отчёт не падает")
	eq(stats2.apps, 2, "без фильтра — все игры")
	check(type(all) == "string" and all:find("Cyberpunk", 1, true) ~= nil, "вторая игра в полном отчёте")
end)

-- ============================ итог ============================
if #failed > 0 then
	error("ПРОВАЛЕНО " .. #failed .. ":\n  " .. table.concat(failed, "\n  "), 0)
end
return "ALL PASSED: " .. passed .. " проверок"
