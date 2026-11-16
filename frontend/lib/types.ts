/** Типы и утилиты для ответов бэкенда (всё приходит JSON-строками). */

export type DepotRow = {
	depotid: string;
	gid: string;
	size: number;
	download: number;
	language?: string;
	dlcappid?: string;
	same_as_installed?: boolean;
	note?: string;
};

export type PlanResult = {
	ok: boolean;
	error?: string;
	appid?: string;
	app_name?: string;
	label?: string;
	branch?: string;
	source?: string;
	depots?: DepotRow[];
	skipped?: { depotid: string; reason: string }[];
	warnings?: string[];
	total_size?: number;
	total_download?: number;
};

export type BranchInfo = {
	branch: string;
	label: string;
	depot_count: number;
	total_size: number;
	total_download: number;
	is_current?: boolean;
};

export type AcfInfo = {
	appid: string;
	name?: string;
	library: string;
	steamapps: string;
	install_dir: string;
	installdir: string;
	language: string;
	beta_key: string;
	buildid?: string;
	size_on_disk: number;
	installed_depots: Record<string, string>;
};

export type AppState = {
	ok: boolean;
	error?: string;
	steam_path?: string;
	libraries?: { path: string; steamapps: string }[];
	apps?: {
		appid: string;
		name: string;
		library: string;
		install_dir: string;
		language: string;
		beta_key: string;
		size_on_disk: number;
		depot_count: number;
	}[];
	config?: { mode: string; include_dlc: boolean; languages: string; delay_updates: boolean; last_appid: string };
};

export type AppDetail = {
	ok: boolean;
	error?: string;
	info?: { appid: string; name: string; installdir?: string; depots: Record<string, { depotid: string; oslist: string; language: string; dlcappid?: string; manifests: Record<string, { gid: string; size: number; download: number }> }> };
	acf?: AcfInfo | null;
	branches?: BranchInfo[];
	backups?: { dirname: string; path: string; created: number; label: string }[];
};

export type JobRow = {
	depo_tid?: string;
	depotid: string;
	gid: string;
	status: 'queued' | 'downloading' | 'ready' | 'failed' | 'cancelled';
	bytes: number;
	expected: number;
	staging: number;
	content_dir?: string;
	error?: string;
	language?: string;
};

export type Snapshot = {
	ok: boolean;
	error?: string;
	active_batch?: boolean;
	batch?: {
		id: number;
		appid: string;
		app_name: string;
		label: string;
		mode: string;
		content_root: string;
		depot_count: number;
		total_size: number;
		total_download: number;
		install_dir: string;
	};
	rows?: JobRow[];
	all_ready?: boolean;
	is_running?: boolean;
	progress?: number;
	done_count?: number;
	failed_count?: number;
	queued_count?: number;
	total_bytes?: number;
	total_expected?: number;
	log?: { t: number; msg: string }[];
};

/** Lua отдаёт пустые таблицы то как [], то как {} — нормализуем в массив. */
export const asArray = <T>(v: unknown): T[] => {
	if (Array.isArray(v)) return v as T[];
	if (v && typeof v === 'object') return Object.values(v as object) as T[];
	return [];
};

export const fmtBytes = (n?: number): string => {
	let v = Number(n ?? 0);
	const units = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'];
	let i = 0;
	while (v >= 1024 && i < units.length - 1) {
		v /= 1024;
		i++;
	}
	return `${v.toFixed(1)} ${units[i]}`;
};

export const fmtTime = (t?: number): string => {
	if (!t) return '';
	const d = new Date(t * 1000);
	return d.toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
};
