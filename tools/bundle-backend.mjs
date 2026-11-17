/**
 * Сборка Lua-бэкенда в один файл backend/main.lua.
 *
 * Зачем: в упакованном .star `require("util")` не находит соседние файлы —
 * package.path внутри LuaVM не содержит папку backend (проверено на живой
 * установке: "module 'util' not found"). Поэтому все наши модули вклеиваются
 * в один файл, а require заменяется на обращение к уже собранной таблице.
 * Модули Millennium (fs, utils, logger, json, http, millennium) остаются
 * обычными require — их предоставляет сам LuaVM.
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const backend = path.join(root, 'backend');

// Порядок важен: модуль может пользоваться только теми, что объявлены выше.
const MODULES = [
	['vdf', 'lib/vdf.lua'],
	['util', 'lib/util.lua'],
	['steam', 'lib/steam.lua'],
	['appinfo', 'lib/appinfo.lua'],
	['localcache', 'lib/localcache.lua'],
	['steamraw', 'lib/steamraw.lua'],
	['steamcounts', 'lib/steamcounts.lua'],
	['appdb', 'lib/appdb.lua'],
	['versiondb', 'lib/versiondb.lua'],
	['collector', 'lib/collector.lua'],
	['plan', 'lib/plan.lua'],
	['jobs', 'lib/jobs.lua'],
	['swap', 'lib/swap.lua'],
	['patches', 'patches.lua'],
	['rpc', 'rpc.lua'],
];

const BOOT = 'boot.lua';
const TARGET = path.join(backend, 'main.lua');

const moduleNames = new Set(MODULES.map(([name]) => name));

/** require("util") -> __modules["util"] для наших модулей, остальное не трогаем. */
const rewriteRequires = (code, file) => {
	return code.replace(/require\s*\(\s*(['"])([A-Za-z0-9_]+)\1\s*\)/g, (whole, _quote, name) => {
		if (!moduleNames.has(name)) return whole;
		return `__modules[${JSON.stringify(name)}]`;
	});
};

const read = (relative) => {
	const full = path.join(backend, relative);
	if (!fs.existsSync(full)) throw new Error(`нет файла ${full}`);
	return fs.readFileSync(full, 'utf8');
};

const chunks = [];
chunks.push(`-- СГЕНЕРИРОВАНО tools/bundle-backend.mjs — не редактировать вручную.
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

__write_marker("vr-boot-start.txt", "start " .. tostring(os.time()) .. "\\n")

local __ok, __result = xpcall(function()
	local __modules = {}
`);

for (const [name, relative] of MODULES) {
	chunks.push(`\n\t-- ===== ${relative} =====\n\t__modules[${JSON.stringify(name)}] = (function()\n`);
	chunks.push(rewriteRequires(read(relative), relative));
	chunks.push('\n\tend)()\n');
}

chunks.push(`\n\t-- ===== ${BOOT} =====\n\treturn (function()\n`);
chunks.push(rewriteRequires(read(BOOT), BOOT));
chunks.push('\n\tend)()\n');
chunks.push(`end, debug.traceback)

if not __ok then
	__write_marker("vr-boot-error.txt", tostring(__result) .. "\\n")
	return {
		on_load = function() end,
		on_unload = function() end,
		patches = {},
	}
end

__write_marker("vr-boot-ok.txt", "loaded " .. tostring(os.time()) .. "\\n")
return __result
`);

fs.writeFileSync(TARGET, chunks.join(''), 'utf8');
const size = fs.statSync(TARGET).size;
console.log(`backend/main.lua собран из ${MODULES.length + 1} файлов (${size} байт)`);
