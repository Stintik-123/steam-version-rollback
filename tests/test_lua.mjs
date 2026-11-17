/**
 * Запуск Lua-проверок под fengari (Lua 5.3 в JS, без установки Lua).
 *
 * Почему не millennium.luavm64.exe: это IPC-хост, он ждёт подключения от
 * Millennium и произвольный скрипт не исполняет.
 *
 * Порядок:
 *   1) синтаксис всех Lua-файлов бэкенда;
 *   2) tests/run.lua — юнит-тесты чистой логики;
 *   3) tests/boot.lua — загрузка собранного backend/main.lua и вызов on_load.
 *
 * Фикстуры и текст собранного бэкенда читаются здесь (в fengari нет io)
 * и передаются в Lua глобальными строками.
 */

import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

const previousDir = process.cwd();
process.chdir(root);

const setGlobal = (name, value) => {
	lua.lua_pushstring(L, to_luastring(value));
	lua.lua_setglobal(L, to_luastring(name));
};

const fail = (message) => {
	console.error(message + '\n' + to_jsstring(lua.lua_tostring(L, -1)));
	lua.lua_close(L);
	process.chdir(previousDir);
	process.exit(1);
};

/** Загрузить файл как чанк и выполнить его. Возвращает значение чанка. */
const runLuaFile = (relative, name) => {
	const code = fs.readFileSync(path.join(root, relative), 'utf8');
	if (lauxlib.luaL_loadbuffer(L, to_luastring(code), null, to_luastring('@' + relative)) !== lua.LUA_OK) {
		fail(`не удалось загрузить ${relative}:`);
	}
	if (lua.lua_pcall(L, 0, 1, 0) !== lua.LUA_OK) {
		fail(`ошибка при выполнении ${relative}:`);
	}
	const value = lua.lua_type(L, -1) === lua.LUA_TSTRING ? to_jsstring(lua.lua_tostring(L, -1)) : '';
	lua.lua_pop(L, 1);
	return value;
};

try {
	// 1. Синтаксис всех Lua-файлов бэкенда.
	const luaFiles = [];
	const walk = (dir) => {
		for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
			const full = path.join(dir, entry.name);
			if (entry.isDirectory()) walk(full);
			else if (entry.name.endsWith('.lua')) luaFiles.push(full);
		}
	};
	walk(path.join(root, 'backend'));

	let syntaxErrors = 0;
	for (const file of luaFiles) {
		const relative = path.relative(root, file).replace(/\\/g, '/');
		const code = fs.readFileSync(file, 'utf8');
		if (lauxlib.luaL_loadbuffer(L, to_luastring(code), null, to_luastring('@' + relative)) !== lua.LUA_OK) {
			console.error(`синтаксис ${relative}: ${to_jsstring(lua.lua_tostring(L, -1))}`);
			lua.lua_pop(L, 1);
			syntaxErrors += 1;
		}
	}
	if (syntaxErrors > 0) {
		lua.lua_close(L);
		process.chdir(previousDir);
		console.error(`\nфайлов с ошибками синтаксиса: ${syntaxErrors}`);
		process.exit(1);
	}
	console.log(`синтаксис Lua: ${luaFiles.length} файл(ов) — ok`);

	// Данные для Lua-скриптов.
	setGlobal('FIXTURE_ACF', fs.readFileSync(path.join(here, 'fixtures', 'appmanifest_1091500.acf'), 'utf8'));
	setGlobal('FIXTURE_LIBRARYFOLDERS', fs.readFileSync(path.join(here, 'fixtures', 'libraryfolders.vdf'), 'utf8'));
	setGlobal('FIXTURE_STEAMCOUNTS', fs.readFileSync(path.join(here, 'fixtures', 'steamcounts_1091500.html'), 'utf8'));
	setGlobal('ENTRY_SOURCE', fs.readFileSync(path.join(root, 'backend', 'main.lua'), 'utf8'));

	// 2. Заглушки и юнит-тесты.
	runLuaFile('tests/stubs.lua');
	console.log('\n' + runLuaFile('tests/run.lua'));

	// 3. Загрузка собранного бэкенда.
	console.log('бэкенд: ' + runLuaFile('tests/boot.lua'));
} finally {
	lua.lua_close(L);
	process.chdir(previousDir);
}
