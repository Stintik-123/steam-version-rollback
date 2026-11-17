/**
 * Сборка общей базы версий: resources/versions-db.json.
 *
 * Зачем: история SteamRaw начинается в сентябре 2026, SteamDB парсить нельзя.
 * Значит, базу нужно копить и поставлять вместе с плагином: берём список сборок
 * из SteamRaw, откатываем манифесты по истории AppInfo (тот же алгоритм, что в
 * backend/lib/steamraw.lua) и складываем снимки в файл базы.
 *
 * Что внутри: только метаданные — buildid, ветка, время и пары depotid -> GID.
 * Никаких ключей депо, никакого обхода прав.
 *
 * Запуск:
 *   node tools/build-versions-db.mjs                 # весь список из versions-db-apps.json
 *   node tools/build-versions-db.mjs 1091500 220     # только эти AppID
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT = path.join(root, 'resources', 'versions-db.json');
const APPS_FILE = path.join(root, 'tools', 'versions-db-apps.json');

const UA = 'VersionRollback/0.1 (Millennium plugin; +https://github.com/Stintik-123/steam-version-rollback)';
const STEAMRAW = 'https://steamraw.com/api';
const STEAMCMD = 'https://api.steamcmd.net/v1/info';
const PAUSE_MS = 900;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function getJson(url) {
	const res = await fetch(url, { headers: { 'User-Agent': UA, Accept: 'application/json' } });
	if (!res.ok) throw new Error(`HTTP ${res.status} — ${url}`);
	return res.json();
}

/** Порт steamraw.reconstruct: манифесты на момент каждой сборки. */
function reconstruct(builds, history, current, branch) {
	const changes = [];
	for (const entry of history) {
		const m = /^depots\.(\d+)\.manifests\.([^.]+)\.gid$/.exec(entry.key ?? '');
		if (m && m[2] === branch) {
			changes.push({ ts: Number(entry.ts) || 0, depotid: m[1], old: entry.old_value, new: entry.new_value });
		}
	}
	changes.sort((a, b) => b.ts - a.ts);
	const oldest = changes.length ? changes[changes.length - 1].ts : null;

	const state = { ...current };
	const relevant = builds
		.filter((b) => String(b.branch) === branch)
		.sort((a, b) => (Number(b.time_updated) || 0) - (Number(a.time_updated) || 0));

	const out = [];
	let index = 0;
	for (const build of relevant) {
		const ts = Number(build.time_updated) || 0;
		while (index < changes.length && changes[index].ts > ts) {
			const change = changes[index];
			const old = change.old == null ? null : String(change.old).trim();
			if (old && /^\d+$/.test(old)) state[change.depotid] = old;
			else delete state[change.depotid];
			index += 1;
		}
		out.push({
			buildid: String(build.buildid),
			ts,
			branch,
			depots: { ...state },
			complete: oldest !== null ? ts >= oldest : Object.keys(state).length === 0,
		});
	}
	return out;
}

async function collectApp(appid, nameHint) {
	const info = await getJson(`${STEAMCMD}/${appid}`);
	const app = info?.data?.[appid] ?? info?.data?.[Number(appid)];
	if (!app) throw new Error('нет данных приложения');

	const builds = await getJson(`${STEAMRAW}/app/${appid}/builds`);
	const history = await getJson(`${STEAMRAW}/app/${appid}/history`);

	// Текущие манифесты по веткам — точка отсчёта для открутки истории назад.
	const currentByBranch = {};
	const branchNames = new Set();
	for (const depot of Object.values(app.depots ?? {})) {
		for (const [branch, manifest] of Object.entries(depot.manifests ?? {})) {
			if (!/^\d+$/.test(String(branch))) continue;
			branchNames.add(branch);
			const gid = manifest?.gid ?? manifest;
			if (!currentByBranch[branch]) currentByBranch[branch] = {};
			if (/^\d+$/.test(String(gid))) currentByBranch[branch][String(depot.id)] = String(gid);
		}
	}

	// У старых игр api.steamcmd.net не отдаёт манифесты — тогда текущее состояние
	// ветки берём из последнего изменения в истории SteamRaw (new_value).
	const latestChange = new Map();
	for (const entry of history) {
		const m = /^depots\.(\d+)\.manifests\.([^.]+)\.gid$/.exec(entry.key ?? '');
		if (!m) continue;
		const ts = Number(entry.ts) || 0;
		const previous = latestChange.get(`${m[1]}:${m[2]}`);
		if (!previous || ts > previous.ts) {
			latestChange.set(`${m[1]}:${m[2]}`, { ts, gid: entry.new_value == null ? null : String(entry.new_value).trim() });
		}
	}
	for (const [key, change] of latestChange) {
		const [depotid, branch] = key.split(':');
		branchNames.add(branch);
		if (!currentByBranch[branch]) currentByBranch[branch] = {};
		if (!currentByBranch[branch][depotid] && change.gid && /^\d+$/.test(change.gid)) {
			currentByBranch[branch][depotid] = change.gid;
		}
	}
	const buildBranches = new Set(builds.map((b) => String(b.branch)));
	const branches = [...branchNames].filter((b) => buildBranches.has(b));
	if (branches.length === 0) branches.push('public');

	const result = { name: app.common?.name ?? nameHint ?? `App ${appid}`, builds: {}, manifests: {} };
	for (const branch of branches) {
		for (const snapshot of reconstruct(builds, history, currentByBranch[branch] ?? {}, branch)) {
			const existing = result.builds[snapshot.buildid];
			const depots = { ...(existing?.depots ?? {}), ...snapshot.depots };
			result.builds[snapshot.buildid] = {
				ts: Math.max(existing?.ts ?? 0, snapshot.ts),
				branch: existing?.branch ?? branch,
				complete: (existing?.complete ?? true) && snapshot.complete,
				depots,
			};
			for (const [depotid, gid] of Object.entries(depots)) {
				result.manifests[`${depotid}:${gid}`] = { depotid, gid, ts: snapshot.ts };
			}
		}
	}

	// Сборка без единого манифеста бесполезна для отката — выкидываем.
	for (const [buildid, build] of Object.entries(result.builds)) {
		if (Object.keys(build.depots).length === 0) delete result.builds[buildid];
	}	for (const key of Object.keys(result.manifests)) {
		const [depotid, gid] = key.split(':');
		const used = Object.values(result.builds).some((b) => b.depots[depotid] === gid);
		if (!used) delete result.manifests[key];
	}
	return { appid, ...result };
}

const args = process.argv.slice(2).filter((a) => /^\d+$/.test(a));
const list = args.length
	? args.map((appid) => ({ appid, name: undefined }))
	: JSON.parse(fs.readFileSync(APPS_FILE, 'utf8'));

const db = { version: 1, updated: Math.floor(Date.now() / 1000), apps: {} };
const failed = [];

for (const entry of list) {
	const appid = String(entry.appid);
	process.stdout.write(`${appid} ${entry.name ?? ''} … `);
	try {
		const app = await collectApp(appid, entry.name);
		if (Object.keys(app.builds).length === 0) {
			process.stdout.write('нет пригодных сборок (нет манифестов) — пропускаю\n');
			continue;
		}
		db.apps[appid] = { name: app.name, builds: app.builds, manifests: app.manifests };
		const count = Object.keys(app.builds).length;
		const manifests = Object.keys(app.manifests).length;
		process.stdout.write(`сборок ${count}, манифестов ${manifests}\n`);
	} catch (error) {
		failed.push(`${appid}: ${error.message}`);
		process.stdout.write(`ОШИБКА ${error.message}\n`);
	}
	await sleep(PAUSE_MS);
}

fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, `${JSON.stringify(db, null, '\t')}\n`, 'utf8');
const size = fs.statSync(OUT).size;
console.log(`\n${OUT} — ${Object.keys(db.apps).length} приложений, ${size} байт`);
if (failed.length) {
	console.log(`не собраны:\n  ${failed.join('\n  ')}`);
	process.exitCode = 1;
}
