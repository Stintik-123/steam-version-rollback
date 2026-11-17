/**
 * Проверка доступности источников истории версий Steam.
 *
 * Зачем: подборка источников живёт в steam-manifest-sources.md, но половина
 * пунктов там не проверена. Этот скрипт честно показывает, что отвечает, что
 * требует ключа, а что недоступно — и не врёт.
 *
 * Запуск: node tools/probe-sources.mjs [appid]
 *
 * ВАЖНО: ключи депо (ManifestHub/SteamTools) здесь не запрашиваются намеренно —
 * это обход прав доступа, в плагине им не место.
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const APPID = process.argv[2] && /^\d+$/.test(process.argv[2]) ? process.argv[2] : '1091500';
const UA = 'VersionRollback/0.1 (Millennium plugin; +https://github.com/Stintik-123/steam-version-rollback)';
const TIMEOUT = 15000;

/** kind: ok | html | json | need-auth | forbidden | dead */
const SOURCES = [
	{ id: 1, name: 'SteamRaw /app', kind: 'json', url: `https://steamraw.com/api/app/${APPID}` },
	{ id: 1, name: 'SteamRaw /builds', kind: 'json', url: `https://steamraw.com/api/app/${APPID}/builds` },
	{ id: 1, name: 'SteamRaw /history', kind: 'json', url: `https://steamraw.com/api/app/${APPID}/history` },
	{ id: 1, name: 'SteamRaw /changelists', kind: 'json', url: `https://steamraw.com/api/app/${APPID}/changelists` },
	{ id: 2, name: 'SteamCounts (HTML)', kind: 'html', url: `https://steamcounts.info/app/${APPID}` },
	{ id: 3, name: 'SteamDB (HTML, автопарсинг запрещён)', kind: 'html', url: `https://steamdb.info/app/${APPID}/depots/` },
	{ id: 4, name: 'opensteamdb-api (только self-host)', kind: 'json', url: 'https://opensteamdb-api.example/api/app/1/info' },
	{ id: 6, name: 'HubcapDB', kind: 'json', url: `https://hubcapmanifest.com/api/depots?appid=${APPID}` },
	{ id: 7, name: "Ryuu's Manifests", kind: 'json', url: `https://manifest-api.ryuu.space/api/app/${APPID}` },
	{ id: 8, name: 'SMD (smd.mcbabel.de)', kind: 'html', url: 'https://smd.mcbabel.de' },
	{ id: 12, name: 'SteamWebPipes (репозиторий)', kind: 'html', url: 'https://github.com/SteamDatabase/SteamTracking' },
	{ id: 13, name: 'Open-SteamDB', kind: 'json', url: `https://opensteamdb.net/api/apps/${APPID}` },
	{ id: 14, name: 'Steam AppDB', kind: 'json', url: `https://steamappdb.net/api/apps/${APPID}` },
	{ id: 17, name: 'SteamCMD API', kind: 'json', url: `https://api.steamcmd.net/v1/info/${APPID}` },
];

async function probe(source) {
	const controller = new AbortController();
	const timer = setTimeout(() => controller.abort(), TIMEOUT);
	try {
		const res = await fetch(source.url, {
			headers: { 'User-Agent': UA, Accept: source.kind === 'json' ? 'application/json' : 'text/html' },
			signal: controller.signal,
			redirect: 'follow',
		});
		const body = await res.text();
		const ctype = res.headers.get('content-type') ?? '';
		let kind = source.kind;
		if (res.status === 401 || res.status === 403) kind = 'need-auth';
		else if (res.status >= 400) kind = 'dead';
		else if (ctype.includes('json') && body.trim().startsWith('{')) kind = 'json';
		else kind = 'html';
		return { ...source, status: res.status, kind, size: body.length, sample: body.slice(0, 120).replace(/\s+/g, ' ') };
	} catch (error) {
		return { ...source, status: 0, kind: 'dead', size: 0, sample: String(error.message).slice(0, 120) };
	} finally {
		clearTimeout(timer);
	}
}

const results = [];
for (const source of SOURCES) {
	const result = await probe(source);
	results.push(result);
	const badge = { json: 'JSON ✓', html: 'HTML', 'need-auth': 'нужен ключ/логин', dead: 'недоступен' }[result.kind] ?? result.kind;
	console.log(`#${String(result.id).padStart(2)} ${result.name.padEnd(42)} ${String(result.status).padStart(3)}  ${badge.padEnd(18)} ${result.size} б  ${result.sample}`);
	await new Promise((r) => setTimeout(r, 400));
}

fs.writeFileSync(path.join(root, 'tools', 'sources-probe.json'), `${JSON.stringify({ appid: APPID, at: new Date().toISOString(), results }, null, '\t')}\n`, 'utf8');
console.log('\nотчёт: tools/sources-probe.json');
