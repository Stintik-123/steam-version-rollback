/**
 * Обёртки над Lua RPC.
 *
 * Обращаемся через globalThis, а не через генерируемый starlight тип `backend`,
 * чтобы фронтенд собирался и typings не обязательны для запуска.
 */

type RpcTable = Record<string, (...args: any[]) => any>;

/**
 * starlight генерирует `backend` как свободную переменную бандла, а не свойство
 * globalThis — поэтому сначала пробуем её, и только потом window.backend.
 */
declare const backend: RpcTable | undefined;

const rpc = (): RpcTable | undefined => {
	if (typeof backend !== 'undefined') return backend;
	return (globalThis as any).backend ?? (globalThis as any).__vrBackend;
};

/** Вызвать backend.<fn>, распарсить JSON-ответ. */
async function call<T>(fn: string, ...args: any[]): Promise<T> {
	const b = rpc();
	if (!b || typeof b[fn] !== 'function') {
		throw new Error(`бэкенд недоступен (backend.${fn}) — плагин включён? Millennium >= 3.4?`);
	}
	const raw = await b[fn](...args);
	if (typeof raw !== 'string') return (raw ?? {}) as T;
	try {
		return JSON.parse(raw) as T;
	} catch {
		throw new Error(`бэкенд вернул не JSON: ${raw.slice(0, 160)}`);
	}
}

export const api = {
	ping: () => call<any>('ping'),
	getState: () => call<any>('get_state'),
	getApp: (appid: string, force = false) => call<any>('get_app', String(appid), force),
	getPlan: (appid: string, selection: object, options: object) =>
		call<any>('get_plan', String(appid), JSON.stringify(selection), JSON.stringify(options)),
	getVersions: (appid: string, branch: string, force = false) =>
		call<any>('get_versions', String(appid), String(branch), force),
	getLocalCache: (appid: string) => call<any>('get_local_cache', String(appid)),
	importManifests: (appid: string, text: string) => call<any>('import_manifests', String(appid), String(text)),
	getDbSummary: (appid: string) => call<any>('get_db_summary', String(appid)),
	collectLocal: (appid: string) => call<any>('collect_local', String(appid)),
	saveLocalDb: (appid: string) => call<any>('save_local_db', String(appid)),
	exportLocal: (appid: string) => call<any>('export_local', String(appid)),
	getSteamCounts: (appid: string, force = false) => call<any>('get_steamcounts', String(appid), force),
	addSteamCountsDb: (appid: string) => call<any>('add_steamcounts_db', String(appid)),
	probeSources: () => call<any>('probe_sources'),
	collectAll: (force = false) => call<any>('collect_all', force),
	collectApp: (appid: string, force = false) => call<any>('collect_app', String(appid), force),
	getCollectionReport: () => call<any>('get_collection_report'),
	postGithubIssue: () => call<any>('post_github_issue'),
	setGithubToken: (token: string) => call<any>('set_github_token', String(token)),
	debugNote: (text: string) => call<any>('debug_note', String(text)),
	start: (appid: string, selection: object, options: object, mode: 'download' | 'swap') =>
		call<any>('start_download', String(appid), JSON.stringify(selection), JSON.stringify(options), mode),
	tick: () => call<any>('tick'),
	cancel: () => call<any>('cancel_download'),
	reset: () => call<any>('reset_batch'),
	markReady: (depotid: string) => call<any>('mark_ready', String(depotid)),
	applySwap: (appid: string) => call<any>('apply_swap', String(appid)),
	restoreBackup: (appid: string, dirname = '') => call<any>('restore_backup', String(appid), String(dirname)),
	listBackups: (appid: string) => call<any>('list_backups', String(appid)),
	delayUpdates: (appid: string, enable: boolean) => call<any>('delay_updates', String(appid), enable),
	openFolder: (path: string) => call<any>('open_folder', String(path)),
	openContentFolder: (appid: string) => call<any>('open_content_folder', String(appid)),
	setSetting: (key: string, value: string) => call<any>('set_setting', String(key), String(value)),
	getLog: () => call<any>('get_log'),
};

/** Открыть ссылку в браузере клиента (SteamDB и прочие справочники). */
export function openExternal(url: string): boolean {
	const sc = (globalThis as any).SteamClient;
	try {
		const execute = sc?.URL?.ExecuteSteamURL;
		if (typeof execute === 'function') {
			execute.call(sc.URL, `steam://openurl/${url}`);
			return true;
		}
	} catch (error) {
		console.error('[Version Rollback] не удалось открыть ссылку через Steam:', error);
	}
	window.open(url, '_blank');
	return true;
}

/** Диагностика: что реально доступно в текущем клиенте Steam. */
export function consoleProbe(): { ok: boolean; detail: string; methodPath?: string } {
	const SC: any = (globalThis as any).SteamClient;
	if (!SC) return { ok: false, detail: 'globalThis.SteamClient не найден — это SharedJSContext?' };
	const candidates = [
		['SteamClient.Console.ExecCommand', SC.Console?.ExecCommand],
		['SteamClient.System.ExecCommand', SC.System?.ExecCommand],
		['SteamClient.Console.ExecuteCommand', SC.Console?.ExecuteCommand],
	];
	const hit = candidates.find(([, fn]) => typeof fn === 'function');
	if (!hit) {
		const namespaces = Object.keys(SC).slice(0, 25).join(', ');
		return { ok: false, detail: `нет Console.ExecCommand. Пространства имён: ${namespaces}… (пришли этот список — подберём другой вход)` };
	}
	return { ok: true, detail: `${hit[0]} — ок`, methodPath: hit[0] };
}

