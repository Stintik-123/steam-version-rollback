/**
 * Обёртки над Lua RPC.
 *
 * ГЛАВНОЕ ПРАВИЛО СТАБИЛЬНОСТИ: в полёте всегда не больше ОДНОГО вызова
 * callServerMethod. Раньше фронтенд умел отправлять несколько запросов
 * одновременно (проба бэкенда + баннер + панель при старте), и совпадение
 * ответов в IPC-слое Millennium заканчивалось падением Lua-хоста
 * (0xC0000409). Поэтому все вызовы идут через последовательную очередь,
 * а каждый вызов ограничен таймаутом — зависший бэкенд больше не может
 * держать фронтенд вечно.
 */

type RpcTable = Record<string, (...args: any[]) => any>;

const PLUGIN_ID = 'com.versionrollback.steam';

/** Таймаут одного RPC-вызова: бэкенд отвечает быстро, это страховка. */
const CALL_TIMEOUT_MS = 25000;
/** Для лёгких вызовов, которые случаются при старте UI. */
const FAST_TIMEOUT_MS = 8000;

declare const backend: RpcTable | undefined;

const rpc = (): RpcTable | undefined => {
	if (typeof backend !== 'undefined') return backend;
	return (globalThis as any).backend ?? (globalThis as any).__vrBackend;
};

const unwrap = (result: any): any => {
	if (result && typeof result === 'object' && 'success' in result) {
		if (!result.success) throw new Error(String(result.error ?? 'FFI вернул ошибку'));
		return result.returnJson;
	}
	return result;
};

/**
 * Имена аргументов для каждой RPC-функции. Millennium передаёт их объектом
 * (callServerMethod(plugin, method, kwargs)), поэтому позиционные аргументы
 * раскладываем по именам — так же, как это делает шаблонный плагин.
 */
const ARG_NAMES: Record<string, string[]> = {
	ping: [],
	get_state: [],
	get_consent: [],
	set_consent: ['value'],
	app_known: ['appid'],
	get_app: ['appid', 'force'],
	get_plan: ['appid', 'selection_json', 'options_json'],
	get_versions: ['appid', 'branch', 'force'],
	start_download: ['appid', 'selection_json', 'options_json', 'mode'],
	tick: [],
	cancel_download: [],
	reset_batch: [],
	mark_ready: ['depotid'],
	apply_swap: ['appid'],
	restore_backup: ['appid', 'dirname'],
	list_backups: ['appid'],
	delay_updates: ['appid', 'enable'],
	open_folder: ['path'],
	open_content_folder: ['appid'],
	set_setting: ['key', 'value'],
	get_log: [],
	debug_note: ['text'],
	get_local_cache: ['appid'],
	import_manifests: ['appid', 'text'],
	get_db_summary: ['appid'],
	collect_local: ['appid'],
	save_local_db: ['appid'],
	export_local: ['appid'],
	get_steamcounts: ['appid', 'force'],
	appdb_search: ['query', 'force'],
	add_steamcounts_db: ['appid'],
	probe_sources: [],
	collect_all: ['force'],
	collect_app: ['appid', 'force'],
	get_collection_report: [],
	submit_app_issue: ['appid'],
	post_github_issue: [],
	set_github_token: ['token'],
};

const toKwargs = (fn: string, args: any[]): Record<string, any> => {
	const names = ARG_NAMES[fn] ?? [];
	const kwargs: Record<string, any> = {};
	names.forEach((name, index) => {
		kwargs[name] = args[index];
	});
	return kwargs;
};

/** Очередь: следующий вызов стартует, когда завершится предыдущий. */
let chain: Promise<unknown> = Promise.resolve();
const enqueue = <T>(task: () => Promise<T>): Promise<T> => {
	const run = (): Promise<T> => task();
	const result = chain.then(run, run);
	chain = result.then(
		(): void => undefined,
		(): void => undefined,
	);
	return result;
};

const withTimeout = <T>(promise: Promise<T>, ms: number, label: string): Promise<T> =>
	new Promise<T>((resolve, reject) => {
		const timer = setTimeout(() => reject(new Error(`бэкенд не ответил за ${ms / 1000} с (${label})`)), ms);
		promise.then(
			(value) => {
				clearTimeout(timer);
				resolve(value);
			},
			(error) => {
				clearTimeout(timer);
				reject(error);
			},
		);
	});

async function callRaw(fn: string, args: any[], timeoutMs: number): Promise<any> {
	return enqueue(async () => {
		const table = rpc();
		if (table && typeof table[fn] === 'function') return unwrap(await withTimeout(table[fn](...args), timeoutMs, fn));

		const millennium = (globalThis as any).Millennium ?? (globalThis as any).MILLENNIUM_API;
		if (typeof millennium?.callServerMethod === 'function') {
			return unwrap(await withTimeout(millennium.callServerMethod(PLUGIN_ID, fn, toKwargs(fn, args)), timeoutMs, fn));
		}

		throw new Error('бэкенд недоступен: нет Millennium.callServerMethod');
	});
}

/** Вызвать функцию бэкенда, распарсить JSON-ответ. */
async function call<T>(fn: string, ...args: any[]): Promise<T> {
	const fast = fn === 'ping' || fn === 'get_consent' || fn === 'app_known' || fn === 'get_state';
	const raw = await callRaw(fn, args, fast ? FAST_TIMEOUT_MS : CALL_TIMEOUT_MS);
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
	/** Решение пользователя по сбору данных: { consent: 'yes'|'no'|'', asked: boolean }. */
	getConsent: () => call<any>('get_consent'),
	setConsent: (value: 'yes' | 'no') => call<any>('set_consent', value),
	/** Есть ли игра в общей базе версий (дёшево, без сети). */
	appKnown: (appid: string) => call<any>('app_known', String(appid)),
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
	/** Поиск AppID по названию игры в открытой базе steam-appdb. */
	appdbSearch: (query: string, force = false) => call<any>('appdb_search', String(query), force),
	addSteamCountsDb: (appid: string) => call<any>('add_steamcounts_db', String(appid)),
	probeSources: () => call<any>('probe_sources'),
	collectAll: (force = false) => call<any>('collect_all', force),
	collectApp: (appid: string, force = false) => call<any>('collect_app', String(appid), force),
	getCollectionReport: () => call<any>('get_collection_report'),
	/** Собрать метаданные одной игры и оформить Issue (авто с токеном, иначе ссылка). */
	submitAppIssue: (appid: string) => call<any>('submit_app_issue', String(appid)),
	postGithubIssue: () => call<any>('post_github_issue'),
	setGithubToken: (token: string) => call<any>('set_github_token', String(token)),
	debugNote: (text: string) => call<any>('debug_note', String(text).slice(0, 400)),
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

/** Открыть ссылку в браузере клиента (SteamDB, GitHub и прочие справочники). */
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

/** Диагностика: что реально доступно в текущем клиенте Steam (DevTools/кнопка). */
export function consoleProbe(): { ok: boolean; detail: string; methodPath?: string } {
	const SC: any = (globalThis as any).SteamClient;
	if (!SC) return { ok: false, detail: 'globalThis.SteamClient не найден — это SharedJSContext?' };
	const candidates: Array<[string, unknown]> = [
		['SteamClient.Console.ExecCommand', SC.Console?.ExecCommand],
		['SteamClient.System.ExecCommand', SC.System?.ExecCommand],
		['SteamClient.Console.ExecuteCommand', SC.Console?.ExecuteCommand],
	];
	const hit = candidates.find(([, fn]) => typeof fn === 'function');
	if (!hit) {
		const namespaces = Object.keys(SC)
			.slice(0, 25)
			.join(', ');
		return { ok: false, detail: `нет Console.ExecCommand. Пространства имён: ${namespaces}… (пришли этот список — подберём другой вход)` };
	}
	return { ok: true, detail: `${hit[0]} — ок`, methodPath: hit[0] };
}
