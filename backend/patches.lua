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
local util = require("util")

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
