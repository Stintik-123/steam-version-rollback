import { Button, DialogButton, DialogButtonPrimary, Dropdown, Field, ProgressBar, TextField, Toggle } from 'millennium';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';

import { api, consoleProbe, openExternal } from '../lib/rpc';
import { CONSENT_KEY, CONSENT_SCOPE, CONSENT_SHOWN_KEY } from '../lib/consts';
import { asArray, fmtBytes, fmtTime, type AppDetail, type AppState, type CollectSummary, type CollectionReport, type ImportResult, type LocalCacheResult, type LocalCollectResult, type PlanResult, type Snapshot, type SourcesProbeResult, type SteamCountsResult, type VersionsResult } from '../lib/types';

const MODE_DOWNLOAD = 'download';
const MODE_SWAP = 'swap';

type CustomRow = { depotid: string; gid: string };

const mono = { fontFamily: 'monospace', fontSize: '11px' } as const;

const styles = {
	wrap: { display: 'flex', flexDirection: 'column' as const, gap: '8px' },
	card: { padding: '10px 12px', borderRadius: '4px', background: 'rgba(0,0,0,.22)' },
	row: { display: 'flex', gap: '8px', alignItems: 'center', flexWrap: 'wrap' as const },
	mono,
	log: { ...mono, maxHeight: '160px', overflowY: 'auto' as const, whiteSpace: 'pre-wrap' as const },
	bad: { color: '#ff6b6b' },
	good: { color: '#7fd88f' },
	warn: { color: '#ffd166' },
};

/**
 * Все источники из подборки (steam-manifest-sources.md) — что подключено,
 * что требует личного ключа, а что отключено сознательно.
 */
type SourceRow = { name: string; gives: string; status: string; url?: string };

const SOURCES: SourceRow[] = [
	{ name: 'SteamRaw', gives: 'сборки + история изменений AppInfo', status: 'подключён: история и манифесты', url: 'https://steamraw.com' },
	{ name: 'api.steamcmd.net', gives: 'текущие депо, ветки, манифесты', status: 'подключён: текущее состояние', url: 'https://api.steamcmd.net' },
	{ name: 'SteamCounts', gives: 'датированные обновления, changelist, текущие GID', status: 'подключён: второй источник и перекрёстная проверка', url: 'https://steamcounts.info' },
	{ name: 'steam-appdb (Austrum-lab)', gives: 'каталог всех AppID: игры, выделенные серверы, ПО', status: 'подключён: поиск игры по названию → AppID', url: 'https://github.com/Austrum-lab/steam-appdb' },
	{ name: 'SteamDB', gives: 'самая длинная история', status: 'только вручную: API нет, автопарсинг запрещён', url: 'https://steamdb.info' },
	{ name: 'opensteamdb-api', gives: 'объединённый API (steam-pics + манифесты)', status: 'не подключён: сервер self-host, публичного нет' },
	{ name: 'ManifestHub / SteamTools', gives: 'ключи депо', status: 'не подключён намеренно: это обход прав' },
	{ name: 'HubcapDB', gives: 'поиск игр и депо', status: 'не подключён: нужен Discord-логин и личный ключ' },
	{ name: "Ryuu's Manifests", gives: 'манифесты по запросу', status: 'не подключён: домен недоступен, нужна авторизация' },
	{ name: 'SMD', gives: 'загрузчик манифестов', status: 'не подключён: тянет данные из ManifestHub/Hubcap (ключи)' },
	{ name: 'steam-downgrader (FlazeIGuess)', gives: 'общий архив метаданных', status: 'идея учтена: своя база версий' },
	{ name: 'steam-downgrader (sendement)', gives: 'локальные appinfo.vdf, content_log.txt, depotcache', status: 'подключено частично: content_log и depotcache читаем' },
	{ name: 'steamarchiver', gives: 'локальный архив AppInfo', status: 'не подключён: это инструмент, а не источник' },
	{ name: 'SteamWebPipes', gives: 'поток changelist через WebSocket', status: 'не подключён: нужен WebSocket-клиент' },
	{ name: 'Open-SteamDB', gives: 'независимая история обновлений', status: 'не подключён: домен не отвечает' },
	{ name: 'Steam AppDB', gives: 'каталог App ID', status: 'не подключён: домен не отвечает' },
	{ name: 'Steam2 Catalog', gives: 'Steam 2003–2013', status: 'не подходит: не SteamPipe' },
	{ name: 'steam-patch-notes', gives: 'тексты патчноутов', status: 'не подключён: только тексты, без манифестов' },
	{ name: 'Локальный appmanifest', gives: 'что установлено и куда качать', status: 'подключён' },
];

export const VersionPanel = ({ appidHint, context }: { appidHint?: string; context?: 'settings' | 'library' }) => {
	const [state, setState] = useState<AppState | null>(null);
	const [appid, setAppid] = useState<string>(appidHint ?? '');
	const [detail, setDetail] = useState<AppDetail | null>(null);
	const [branch, setBranch] = useState<string>('');
	const [custom, setCustom] = useState<CustomRow[]>([]);
	const [customDraft, setCustomDraft] = useState<CustomRow>({ depotid: '', gid: '' });
	const [useCustom, setUseCustom] = useState(false);
	const [mode, setMode] = useState<'download' | 'swap'>(MODE_DOWNLOAD);
	const [includeDlc, setIncludeDlc] = useState(false);
	const [languages, setLanguages] = useState('english,russian');
	const [plan, setPlan] = useState<PlanResult | null>(null);
	const [snap, setSnap] = useState<Snapshot | null>(null);
	const [busy, setBusy] = useState(false);
	const [versions, setVersions] = useState<VersionsResult | null>(null);
	const [versionsBusy, setVersionsBusy] = useState(false);
	const [versionPick, setVersionPick] = useState(-1);
	const [localCache, setLocalCache] = useState<LocalCacheResult | null>(null);
	const [localBusy, setLocalBusy] = useState(false);
	const [importText, setImportText] = useState('');
	const [importBusy, setImportBusy] = useState(false);
	const [collectEnabled, setCollectEnabled] = useState(false);
	const [collect, setCollect] = useState<LocalCollectResult | null>(null);
	const [collectBusy, setCollectBusy] = useState(false);
	const [exportPath, setExportPath] = useState('');
	const [sc, setSc] = useState<SteamCountsResult | null>(null);
	const [scBusy, setScBusy] = useState(false);
	const [appQuery, setAppQuery] = useState('');
	const [appdbResults, setAppdbResults] = useState<{ appid: string; name: string }[]>([]);
	const [appdbBusy, setAppdbBusy] = useState(false);
	const [sourcesProbe, setSourcesProbe] = useState<SourcesProbeResult | null>(null);
	const [probeBusy, setProbeBusy] = useState(false);
	const [consent, setConsent] = useState('');
	const [consentShownFor, setConsentShownFor] = useState('');
	const [collectSummary, setCollectSummary] = useState<CollectSummary | null>(null);
	const [report, setReport] = useState<CollectionReport | null>(null);
	const [collectAllBusy, setCollectAllBusy] = useState(false);
	const [token, setToken] = useState('');
	const [message, setMessage] = useState('');
	const [probe, setProbe] = useState<{ ok: boolean; detail: string } | null>(null);
	const timer = useRef<any>(null);

	const selection = useMemo<object>(() => (useCustom ? { custom } : { branch }), [useCustom, custom, branch]);
	const options = useMemo<object>(() => ({ include_dlc: includeDlc, languages: languages.split(/[\s,]+/).filter(Boolean) }), [includeDlc, languages]);

	// Локальный кэш Steam: depotid -> множество манифестов, которые Steam уже видел.
	const knownManifests = useMemo(() => {
		const map = new Map<string, Set<string>>();
		for (const row of asArray<{ depotid: string; gids: string[] }>(localCache?.depots)) {
			map.set(row.depotid, new Set(asArray<string>(row.gids)));
		}
		return map;
	}, [localCache]);

	/** Сколько депо этой сборки Steam уже видел на этом компьютере. */
	const matchLocal = (depots: Record<string, string>) => {
		const entries = Object.entries(depots ?? {});
		const total = entries.length;
		let matched = 0;
		for (const [depotid, gid] of entries) {
			if (knownManifests.get(depotid)?.has(gid)) matched += 1;
		}
		return { total, matched, full: total > 0 && matched === total };
	};

	const fail = (e: unknown) => setMessage(String(e instanceof Error ? e.message : e));

	const loadState = useCallback(async () => {
		const s = await api.getState();
		setState(s);
		if (!s.ok) return fail(s.error ?? 'бэкенд не ответил');
		if (!appid && s.config?.last_appid) setAppid(String(s.config.last_appid));
		if (s.config?.languages) setLanguages(String(s.config.languages));
		setIncludeDlc(Boolean(s.config?.include_dlc));
		setCollectEnabled(Boolean(s.config?.local_collect));
		setConsent(String(s.config?.collect_consent ?? ''));
		setConsentShownFor(String(s.config?.consent_shown_for ?? ''));
		setMode(s.config?.mode === MODE_SWAP ? MODE_SWAP : MODE_DOWNLOAD);
	}, [appid]);

	useEffect(() => {
		loadState().catch(fail);
	}, []);

	const loadApp = useCallback(async (force = false) => {
		if (!appid) return fail('укажи AppID или выбери игру из списка');
		setBusy(true);
		try {
			const d = await api.getApp(appid, force);
			setDetail(d);
			if (!d.acf) setMode(MODE_DOWNLOAD);
			if (!d.ok) return setMessage(d.error ?? 'не удалось получить данные депо');
			const branches = asArray<{ branch: string; is_current?: boolean }>(d.branches);
			const current = branches.find((b) => b.is_current)?.branch ?? branches[0]?.branch ?? 'public';
			setBranch(current);
			setPlan(null);
			setMessage(branches.length ? `веток: ${branches.length}` : 'ветки не найдены');
		} catch (e) {
			fail(e);
		} finally {
			setBusy(false);
		}
	}, [appid]);

	// История сборок из SteamRaw: манифесты восстанавливаются из изменений AppInfo.
	const loadVersions = async () => {
		setVersionsBusy(true);
		try {
			const result = (await api.getVersions(appid, branch || 'public')) as VersionsResult;
			setVersions(result);
			setVersionPick(result.ok && result.versions && result.versions.length > 0 ? 0 : -1);
			setMessage(result.ok ? `сборок в истории: ${result.versions?.length ?? 0}` : (result.error ?? 'история недоступна'));
		} catch (error) {
			fail(error);
		} finally {
			setVersionsBusy(false);
		}
	};

	const applyVersion = () => {
		const entry = versions?.versions?.[versionPick];
		if (!entry) return;
		const installed = detail?.acf ? new Set(Object.keys(detail.acf.installed_depots ?? {})) : null;
		const rows = Object.entries(entry.depots)
			.filter(([depotid]) => !installed || installed.has(depotid))
			.map(([depotid, gid]) => ({ depotid, gid }));
		if (rows.length === 0) {
			setMessage('в этой сборке нет депо, которые установлены у вас');
			return;
		}
		setCustom(rows);
		setUseCustom(true);
		setPlan(null);
		setMessage(`подставлено депо: ${rows.length} · build ${entry.buildid}${entry.complete ? '' : ' · сборка старше истории SteamRaw'}`);
	};

	// Локальный кэш: что Steam уже видел на этой машине (content_log + depotcache + ACF).
	const loadLocalCache = async () => {
		setLocalBusy(true);
		try {
			const result = (await api.getLocalCache(appid)) as LocalCacheResult;
			setLocalCache(result);
			const depots = asArray<{ depotid: string }>(result.depots);
			setMessage(result.ok ? `локально известно депо: ${depots.length}` : (result.error ?? 'локальный кэш недоступен'));
		} catch (error) {
			fail(error);
		} finally {
			setLocalBusy(false);
		}
	};

	// Ручной импорт списка депо -> GID (из SteamDB вручную, без парсинга сайта).
	const runImport = async () => {
		if (!importText.trim()) return setMessage('вставьте список «депо GID»');
		setImportBusy(true);
		try {
			const result = (await api.importManifests(appid, importText)) as ImportResult;
			const rows = asArray<{ depotid: string; gid: string }>(result.rows);
			const problems = asArray<string>(result.problems);
			if (rows.length > 0) {
				setCustom(rows);
				setUseCustom(true);
				setPlan(null);
			}
			setMessage(`импортировано депо: ${rows.length}${problems.length ? ` · не разобрано строк: ${problems.length}` : ''}`);
		} catch (error) {
			fail(error);
		} finally {
			setImportBusy(false);
		}
	};

	const addToPlan = (depotid: string, gid: string) => {
		setCustom([...custom, { depotid, gid }]);
		setUseCustom(true);
		setPlan(null);
		setMessage(`депо ${depotid} → ${gid} добавлено в план`);
	};

	// Согласие на локальный сбор: без него бэкенд ничего не читает.
	const toggleCollect = (value: boolean) => {
		setCollectEnabled(value);
		api.setSetting(CONSENT_KEY, value ? 'yes' : 'no').catch((): void => undefined);
		api.setSetting(CONSENT_SHOWN_KEY, CONSENT_SCOPE).catch((): void => undefined);
		setConsent(value ? 'yes' : 'no');
		setConsentShownFor(CONSENT_SCOPE);
		window.dispatchEvent(new Event('vrb-consent-changed'));
		setMessage(value ? 'локальный сбор включён' : 'локальный сбор выключен');
	};

	const runCollect = async () => {
		setCollectBusy(true);
		try {
			const result = (await api.collectLocal(appid)) as LocalCollectResult;
			setCollect(result);
			setMessage(result.ok ? `локально найдено манифестов: ${result.total ?? 0}` : (result.error ?? 'сбор не удался'));
		} catch (error) {
			fail(error);
		} finally {
			setCollectBusy(false);
		}
	};

	const runSaveLocalDb = async () => {
		try {
			const result = await api.saveLocalDb(appid);
			setMessage(result.ok ? `сохранено в локальную базу: ${result.added ?? 0}` : (result.error ?? 'не сохранилось'));
		} catch (error) {
			fail(error);
		}
	};

	const runExportLocal = async () => {
		try {
			const result = await api.exportLocal(appid);
			setExportPath(String(result.path ?? ''));
			setMessage(result.ok ? `отчёт сохранён: ${result.path} (записей: ${result.count ?? 0})` : (result.error ?? 'не выгрузилось'));
		} catch (error) {
			fail(error);
		}
	};

	// Каталог AppID из steam-appdb: ищем игру по названию.
	const runAppdbSearch = async (force = false) => {
		setAppdbBusy(true);
		try {
			const result = (await api.appdbSearch(appQuery, force)) as { ok: boolean; error?: string; results?: { appid: string; name: string }[] };
			if (!result?.ok) {
				setAppdbResults([]);
				setMessage(result?.error ?? 'steam-appdb недоступен');
				return;
			}
			setAppdbResults(asArray(result.results));
			setMessage(`steam-appdb: найдено ${asArray(result.results).length}`);
		} catch (error) {
			fail(error);
		} finally {
			setAppdbBusy(false);
		}
	};

	// SteamCounts: второй источник — датированные обновления и текущие GID.
	const loadSteamCounts = async (force = false) => {
		setScBusy(true);
		try {
			const result = (await api.getSteamCounts(appid, force)) as SteamCountsResult;
			setSc(result);
			setMessage(result.ok ? `SteamCounts: обновлений ${asArray(result.updates).length} · депо ${asArray(result.depots).length}` : (result.error ?? 'SteamCounts недоступен'));
		} catch (error) {
			fail(error);
		} finally {
			setScBusy(false);
		}
	};

	const runAddSteamCountsDb = async () => {
		try {
			const result = await api.addSteamCountsDb(appid);
			setMessage(result.ok ? `в локальную базу добавлено манифестов: ${result.added ?? 0}` : (result.error ?? 'не добавилось'));
		} catch (error) {
			fail(error);
		}
	};

	const runProbeSources = async () => {
		setProbeBusy(true);
		try {
			const result = (await api.probeSources()) as SourcesProbeResult;
			setSourcesProbe(result);
			setMessage('проверка источников закончена');
		} catch (error) {
			fail(error);
		} finally {
			setProbeBusy(false);
		}
	};

	// Сбор по всем установленным играм + отчёт для Issue.
	// Идём по одной игре: так каждый вызов короткий и не упирается в таймаут RPC.
	const runCollectAll = async (force = false) => {
		setCollectAllBusy(true);
		const installed = asArray<{ appid: string; name: string }>(state?.apps);
		const rows: { appid: string; name?: string; builds: number; manifests: number; errors: string[] }[] = [];
		let builds = 0;
		let manifests = 0;
		try {
			for (let i = 0; i < installed.length; i++) {
				const app = installed[i];
				setMessage(`сбор: ${app.name ?? app.appid} (${i + 1}/${installed.length})`);
				const r = (await api.collectApp(app.appid, force)) as {
					ok: boolean;
					error?: string;
					builds?: number;
					manifests?: number;
					errors?: string[];
				};
				if (r.ok) {
					builds += r.builds ?? 0;
					manifests += r.manifests ?? 0;
					rows.push({
						appid: app.appid,
						name: app.name,
						builds: r.builds ?? 0,
						manifests: r.manifests ?? 0,
						errors: asArray<string>(r.errors),
					});
				} else {
					rows.push({ appid: app.appid, name: app.name, builds: 0, manifests: 0, errors: [r.error ?? 'ошибка'] });
				}
			}
			const summary: CollectSummary = {
				ok: true,
				total_apps: installed.length,
				builds,
				manifests,
				errors: rows.filter((r) => r.errors.length > 0).length,
				apps: rows,
			};
			setCollectSummary(summary);
			setMessage(`собрано: игр ${installed.length} · новых сборок ${builds} · манифестов ${manifests}`);
			const rep = (await api.getCollectionReport()) as CollectionReport;
			setReport(rep);
		} catch (error) {
			fail(error);
		} finally {
			setCollectAllBusy(false);
		}
	};

	// Ответ на карточку обновления: да / нет.
	const answerConsent = async (yes: boolean) => {
		try {
			await api.setSetting('collect_consent', yes ? 'yes' : 'no');
			await api.setSetting('consent_shown_for', CONSENT_SCOPE);
			setConsent(yes ? 'yes' : 'no');
			setConsentShownFor(CONSENT_SCOPE);
			window.dispatchEvent(new Event('vrb-consent-changed'));
			setCollectEnabled(yes);
			setMessage(yes ? 'спасибо: сбор включён, запускаю сбор по всем играм' : 'сбор отключён — плагин ничего не читает и никуда не отправляет');
			if (yes) await runCollectAll(false);
		} catch (error) {
			fail(error);
		}
	};

	const saveToken = async () => {
		try {
			const result = await api.setGithubToken(token);
			setMessage(result.ok ? (result.saved ? 'токен сохранён' : 'токен удалён') : (result.error ?? 'не сохранилось'));
			if (result.ok && result.saved) setToken('');
		} catch (error) {
			fail(error);
		}
	};

	const postIssue = async () => {
		try {
			const result = await api.postGithubIssue();
			setMessage(result.ok ? `Issue создан: ${result.url ?? result.number}` : (result.error ?? 'не создался'));
		} catch (error) {
			fail(error);
		}
	};

	// строим план при смене выбора
	useEffect(() => {
		if (!appid || !detail?.ok) return;
		if (useCustom && custom.length === 0) {
			setPlan(null);
			return;
		}
		api.getPlan(appid, selection, options)
			.then((p) => setPlan(p as PlanResult))
			.catch(fail);
	}, [appid, detail, selection, options, useCustom, custom]);

	// поллинг прогресса, пока что-то качается
	useEffect(() => {
		const active = snap?.is_running || snap?.active_batch;
		if (!active) return undefined;
		timer.current = setInterval(async () => {
			try {
				const s = await api.tick();
				setSnap(s as Snapshot);
			} catch (e) {
				fail(e);
			}
		}, 2000);
		return () => clearInterval(timer.current);
	}, [snap?.is_running, snap?.active_batch]);

	const start = async () => {
		setBusy(true);
		try {
			const s = (await api.start(appid, selection, options, mode)) as Snapshot;
			setSnap(s);
			if (!s.ok) setMessage(s.error ?? 'не удалось начать');
			else setMessage(`в очередь поставлено депо: ${s.batch?.depot_count ?? 0}`);
		} catch (e) {
			fail(e);
		} finally {
			setBusy(false);
		}
	};

	const run = async (label: string, fn: () => Promise<any>) => {
		setBusy(true);
		try {
			const r = await fn();
			setSnap(typeof r?.rows === 'object' || r?.batch ? r : snap);
			setMessage(r?.ok ? `${label}: ок` : `${label}: ${r?.error ?? 'не получилось'}`);
			if (r?.backup_dir) setMessage(`${label}: ок. Старая версия в ${r.backup_dir}`);
		} catch (e) {
			fail(e);
		} finally {
			setBusy(false);
		}
	};

	const apps = asArray<{ appid: string; name: string }>(state?.apps);
	const branchOptions = asArray<{ branch: string; label: string; total_size: number; depot_count: number; is_current?: boolean }>(detail?.branches);
	// Без установленной игры подменять нечего — режим принудительно «только скачать».
	const notInstalled = Boolean(detail?.ok && !detail.acf);
	const rows = asArray<any>(snap?.rows);
	const probeResult = () => setProbe(consoleProbe());

	return (
		<div style={styles.wrap}>
			<Field label="Version Rollback" description="Откат/выбор конкретной версии игры: Steam качает нужный манифест депо сам, по твоему аккаунту." bottomSeparator="thick">
				<DialogButton onClick={() => probeResult()}>Диагностика API</DialogButton>
			</Field>

			{probe && (
				<div style={{ ...styles.card, ...(probe.ok ? styles.good : styles.warn) }}>
					{probe.ok ? '✔ ' : '⚠ '}
					{probe.detail}
				</div>
			)}
			{message && <div style={styles.card}>{message}</div>}

			{consentShownFor !== CONSENT_SCOPE && context !== 'settings' && (
				<div style={{ ...styles.card, ...styles.warn }}>
					<div>
						<b>Version Rollback: сбор метаданных о версиях — вопрос один раз</b>
					</div>
					<div style={{ marginTop: '6px' }}>
						Теперь плагин умеет собирать версии по максимуму: по всем установленным играм берутся
						локальные кэши Steam (content_log.txt, depotcache, appmanifest), сборки и снимки манифестов
						из SteamRaw и текущие GID из SteamCounts. Всё это — метаданные: AppID, buildid, depotid и
						manifest GID. Никаких ключей депо, никакого обхода прав.
					</div>
					<div style={{ marginTop: '6px' }}>
						<b>Собирать данные о версиях с вашего компьютера?</b> Если «да» — плагин соберёт их в
						локальную базу и покажет отчёт, который можно отправить в Issue проекта на GitHub
						(отправляете его вы сами). Если «нет» — плагин ничего не читает и никуда не отправляет.
					</div>
					<div style={{ ...styles.row, marginTop: '8px' }}>
						<DialogButtonPrimary onClick={() => answerConsent(true)}>Да, собирать</DialogButtonPrimary>
						<DialogButton onClick={() => answerConsent(false)}>Нет, не собирать</DialogButton>
					</div>
				</div>
			)}

			<Field label="Игра" description="Список — из установленных в Steam. Можно вбить AppID вручную." bottomSeparator="standard">
				<Dropdown
					rgOptions={apps.map((a) => ({ data: a.appid, label: `${a.name} (${a.appid})` }))}
					selectedOption={apps.findIndex((a) => a.appid === appid)}
					strDefaultLabel={appid ? '— не из списка —' : 'Выбери установленную игру'}
					onChange={(o: any) => {
						setAppid(String(o.data));
						setDetail(null);
						setPlan(null);
					}}
				/>
			</Field>

			<TextField label="AppID" value={appid} onChange={(e) => setAppid(e.currentTarget.value.trim())} mustBeNumeric description="например 1091500" />

			<Field label="Поиск игры по названию" description="steam-appdb: открытая база всех AppID (игры, выделенные серверы, ПО)" bottomSeparator="standard">
				<div style={styles.row}>
					<input
						style={{
							padding: '6px 8px',
							borderRadius: 4,
							border: '1px solid rgba(255,255,255,.25)',
							background: 'rgba(0,0,0,.35)',
							color: 'inherit',
							font: 'inherit',
							minWidth: 220,
						}}
						placeholder="например Team Fortress 2"
						value={appQuery}
						onChange={(e) => setAppQuery(e.currentTarget.value)}
					/>
					<DialogButton onClick={() => runAppdbSearch()} disabled={busy || appdbBusy || !appQuery.trim()}>
						{appdbBusy ? 'Ищу…' : 'Найти AppID'}
					</DialogButton>
					<DialogButton onClick={() => runAppdbSearch(true)} disabled={busy || appdbBusy || !appQuery.trim()}>						Обновить базу
					</DialogButton>
				</div>
				{appdbResults.length > 0 && (
					<div style={{ ...styles.mono, marginTop: '8px' }}>
						{appdbResults.map((r) => (
							<div key={r.appid}>
								<button
									type="button"
									style={{ background: 'none', border: 'none', color: '#66c0f4', cursor: 'pointer', padding: 0, font: 'inherit' }}
									onClick={() => {
										setAppid(r.appid);
										setAppQuery(r.name);
									}}
								>
									{r.name}
								</button>{' '}
								— AppID {r.appid}
							</div>
						))}
					</div>
				)}
			</Field>

			<Field label="Данные депо" description="api.steamcmd.net, кэш 6 часов" bottomSeparator="standard">
				<DialogButton onClick={() => loadApp(false)} disabled={busy}>Подтянуть</DialogButton>
				<DialogButton onClick={() => loadApp(true)} disabled={busy}>Обновить принудительно</DialogButton>
				<DialogButton onClick={() => openExternal(`https://steamdb.info/app/${appid}/depots/`)} disabled={!appid}>
					SteamDB: депо
				</DialogButton>
			</Field>

			{detail?.acf && (
				<div style={styles.card}>
					<div>Установлено: <b>{detail.acf.name}</b> · библиотека {detail.acf.library}</div>
					<div style={styles.mono}>папка: {detail.acf.install_dir}</div>
					<div style={styles.mono}>текущая ветка: {detail.acf.beta_key} · buildid {detail.acf.buildid ?? '?'} · депо {Object.keys(detail.acf.installed_depots || {}).length} · язык {detail.acf.language}</div>
				</div>
			)}

			<Field label="Версия" description="Ветки, которые разработчик выложил в публичный доступ (в т.ч. legacy-ветки вроде 2_31_old у Cyberpunk)." bottomSeparator="standard">
				<Dropdown
					rgOptions={branchOptions.map((b) => ({
						data: b.branch,
						label: `${b.label}${b.is_current ? ' ← сейчас' : ''} · ${b.depot_count} депо · ~${fmtBytes(b.total_size)}`,
					}))}
					selectedOption={branchOptions.findIndex((b) => b.branch === branch)}
					strDefaultLabel={branch || '—'}
					disabled={useCustom}
					onChange={(o: any) => setBranch(String(o.data))}
				/>
			</Field>

			{detail?.ok && branchOptions.length === 0 && (
				<div style={{ ...styles.card, ...styles.warn }}>
					У этой игры нет публичных веток — значит, готовой «старой версии» в Steam нет. Но версию всё равно можно поставить:
					включите ниже «Свой manifest ID» и возьмите GID депо из SteamDB (кнопка «SteamDB: депо»), вкладка Depots → нужный depot → Manifest.
				</div>
			)}

			{notInstalled && (
				<div style={{ ...styles.card, ...styles.warn }}>
					Игра не установлена. Скачается в <code>steamapps/content/app_{appid}</code> в библиотеку с максимумом свободного места;
					подмена файлов недоступна — файлы можно взять оттуда вручную. Режим принудительно «только скачать».
				</div>
			)}

			<Field label="История версий" description="SteamRaw: сборки с сентября 2026; манифесты восстанавливаются из истории изменений AppInfo. Плюс общая база версий, накопленная ранее." bottomSeparator="standard">
				<DialogButton onClick={loadVersions} disabled={busy || versionsBusy || !appid}>
					{versionsBusy ? 'Загружаю…' : 'Загрузить историю'}
				</DialogButton>
			</Field>

			{versions && (
				<div style={styles.card}>
					{versions.ok ? (
						(asArray<{ buildid: string; ts: number; branch?: string; depots: Record<string, string>; complete: boolean; source?: string }>(versions.versions).length > 0) ? (
							<>
								{versions.db?.in_db && (
									<div style={styles.mono}>
										В общей базе: сборок {versions.db.builds ?? 0} · манифестов {versions.db.manifests ?? 0}
									</div>
								)}
								<Dropdown
									rgOptions={asArray<{ buildid: string; ts: number; branch?: string; depots: Record<string, string>; complete: boolean; source?: string }>(versions.versions).map((v, i) => {
										const local = matchLocal(v.depots);
										const fromDb = String(v.source ?? '').includes('db');
										const branchTag = v.branch && v.branch !== (versions?.branch ?? 'public') ? ` · ${v.branch}` : '';
										return {
											data: i,
											label: `build ${v.buildid}${branchTag} · ${new Date(v.ts * 1000).toLocaleString('ru-RU')} · депо ${Object.keys(v.depots).length}${v.complete ? '' : ' · неполная'}${fromDb ? ' · из базы' : ''}${local.full ? ' · была на этом ПК' : local.matched > 0 ? ` · локально ${local.matched}/${local.total}` : ''}`,
										};
									})}
									selectedOption={versionPick}
									strDefaultLabel="выберите сборку"
									onChange={(o: any) => setVersionPick(Number(o.data))}
								/>
								<DialogButton onClick={applyVersion} disabled={versionPick < 0}>
									Подставить манифесты в план
								</DialogButton>
							</>
						) : (
							<div style={styles.warn}>В истории SteamRaw и в общей базе нет сборок для этой ветки — источник собирает данные только с сентября 2026.</div>
						)
					) : (
						<div style={styles.bad}>{versions.error}</div>
					)}
				</div>
			)}

			{consentShownFor !== CONSENT_SCOPE && context === 'settings' && (
				<div style={{ ...styles.card, ...styles.warn }}>
					Выбор «собирать ли данные о версиях» задаётся не здесь, а в разделе <b>Библиотека</b> Steam:
					баннер в правом нижнем углу или блок в «Свойства → Версии и бета-версии». Пока решение не принято,
					плагин не читает ни <code>content_log.txt</code>, ни <code>depotcache</code>, ни что-либо ещё.
				</div>
			)}

			<Field label="Локальный сбор данных" description="Чтение локальных кэшей Steam — только по вашему явному согласию." bottomSeparator="standard">
				<Toggle value={collectEnabled} onChange={toggleCollect} />
				<div style={{ ...styles.mono, marginTop: '4px' }}>
					Текущее решение: {consent === 'yes' ? 'сбор разрешён' : consent === 'no' ? 'сбор запрещён' : 'решение не принято'}
					{consentShownFor ? ` (отметка вопроса: ${consentShownFor})` : ''}
				</div>
			</Field>

			<div style={{ ...styles.card, ...styles.warn }}>
				<div>
					<b>Что такое локальный сбор.</b> Плагин читает локальные кэши Steam — <code>logs/content_log.txt</code>,{' '}
					<code>steamapps/depotcache/*.manifest</code>, <code>appmanifest_*.acf</code> — и ищет манифесты версий, которых ещё нет в общей базе.
					Это единственный способ узнать про версии старше сентября 2026: SteamRaw тогда ещё не собирал историю, а SteamDB парсить нельзя.
				</div>
				<div style={{ marginTop: '6px' }}>
					Ничего не уходит наружу само: сетевые запросы идут только к публичным API SteamRaw и steamcmd.net, и только с публичным AppID игры.
					Экспорт отчёта — исключительно по вашему нажатию, и в отчёте лишь пары <code>depotid → manifest GID</code>: без аккаунта, без machine-id, без ключей депо.
					Сбор выключен по умолчанию и читает только файлы выбранной игры.
				</div>
			</div>

			<div style={styles.row}>
				<DialogButton onClick={runCollect} disabled={busy || collectBusy || !appid || !collectEnabled}>
					{collectBusy ? 'Собираю…' : 'Собрать локальные версии'}
				</DialogButton>
				<DialogButton onClick={runSaveLocalDb} disabled={busy || !appid || !collectEnabled}>
					Сохранить в локальную базу
				</DialogButton>
				<DialogButton onClick={runExportLocal} disabled={busy || !appid || !collectEnabled}>
					Экспортировать отчёт
				</DialogButton>
				{exportPath && <DialogButton onClick={() => run('папка', () => api.openFolder(exportPath))}>Открыть отчёт</DialogButton>}
			</div>

			<div style={styles.row}>
				<DialogButtonPrimary onClick={() => runCollectAll(false)} disabled={busy || collectAllBusy || !collectEnabled}>
					{collectAllBusy ? 'Собираю по всем играм…' : 'Собрать по всем играм'}
				</DialogButtonPrimary>
				<DialogButton onClick={() => runCollectAll(true)} disabled={busy || collectAllBusy || !collectEnabled}>
					Собрать по всем играм (без кэша)
				</DialogButton>
			</div>

			{collectSummary && (
				<div style={styles.card}>
					{collectSummary.ok ? (
						<>
							<div>
								Игр обработано: {collectSummary.total_apps ?? 0} · новых сборок: {collectSummary.builds ?? 0} · манифестов:{' '}
								{collectSummary.manifests ?? 0}
							</div>
							{asArray<{ appid: string; name?: string; builds: number; manifests: number; errors: string[] }>(collectSummary.apps)
								.slice(0, 60)
								.map((a) => (
									<div key={a.appid} style={styles.mono}>
										{a.name ?? a.appid} ({a.appid}) — сборок {a.builds} · манифестов {a.manifests}
										{asArray<string>(a.errors).length > 0 ? ` · ошибки: ${asArray<string>(a.errors).join('; ')}` : ''}
									</div>
								))}
							{collectSummary.saved_to && <div style={styles.mono}>локальная база: {collectSummary.saved_to}</div>}
						</>
					) : (
						<div style={styles.bad}>{collectSummary.error}</div>
					)}
				</div>
			)}

			{report?.ok && (
				<div style={styles.card}>
					<div>
						Отчёт для Issue: игр {report.stats?.apps ?? 0} · сборок {report.stats?.builds ?? 0}
						{report.truncated ? ' · тело урезано (полный отчёт — в файле или через токен)' : ''}
					</div>
					<div style={{ ...styles.row, marginTop: '6px' }}>
						<DialogButtonPrimary onClick={() => openExternal(report.url as string)}>Открыть Issue на GitHub</DialogButtonPrimary>
						<DialogButton onClick={postIssue}>Создать Issue автоматически</DialogButton>
						<DialogButton onClick={() => openExternal('https://github.com/settings/tokens/new?scopes=repo&description=Version+Rollback')}>
							Создать токен на GitHub
						</DialogButton>
					</div>
					<TextField
						label="GitHub-токен (для автосоздания Issue)"
						value={token}
						onChange={(e) => setToken(e.currentTarget.value.trim())}
						description="personal access token с правом repo. Хранится в настройках Millennium."
					/>
					<DialogButton onClick={saveToken} disabled={!token}>
						Сохранить токен
					</DialogButton>
				</div>
			)}

			{collect && (
				<div style={styles.card}>
					{collect.ok ? (
						<>
							<div>
								Локально найдено манифестов: {collect.total ?? 0} · уже в базе: {asArray(collect.known).length} · новых: {asArray(collect.missing).length}
							</div>
							{collect.build && (
								<div style={styles.mono}>
									Установленная версия: build {collect.build.buildid} · ветка {collect.build.branch} · {collect.build.in_db ? 'уже в базе' : 'нет в базе'}
								</div>
							)}
							{asArray<{ depotid: string; gid: string; source: string }>(collect.missing).slice(0, 40).map((m) => (
								<div key={`${m.depotid}-${m.gid}`} style={{ ...styles.row, ...styles.mono }}>
									<span>
										депо {m.depotid} → {m.gid} <span style={styles.mono}>({m.source})</span>
									</span>
									<Button onClick={() => addToPlan(m.depotid, m.gid)}>в план</Button>
								</div>
							))}
						</>
					) : (
						<div style={styles.bad}>{collect.error}</div>
					)}
				</div>
			)}

			<Field label="Локальный кэш Steam" description="content_log.txt + depotcache + appmanifest: манифесты, которые Steam уже видел на этом компьютере. Помогает найти версии старше истории SteamRaw." bottomSeparator="standard">
				<DialogButton onClick={loadLocalCache} disabled={busy || localBusy || !appid}>
					{localBusy ? 'Смотрю…' : 'Проверить локальный кэш'}
				</DialogButton>
			</Field>

			{localCache && (
				<div style={styles.card}>
					{localCache.ok ? (
						asArray<{ depotid: string; gids: string[] }>(localCache.depots).length > 0 ? (
							<>
								<div>Записей в локальном кэше: {localCache.entry_count ?? 0}</div>
								{asArray<{ depotid: string; gids: string[] }>(localCache.depots).map((d) => (
									<div key={d.depotid} style={styles.mono}>
										депо {d.depotid}:
										{asArray<string>(d.gids).map((gid) => (
											<span key={gid}>
												{' '}
												{gid}
												<Button onClick={() => addToPlan(d.depotid, gid)}>в план</Button>
											</span>
										))}
									</div>
								))}
							</>
						) : (
							<div style={styles.warn}>Локально по этой игре ничего не нашлось: content_log.txt пуст или его нет, depotcache пуст.</div>
						)
					) : (
						<div style={styles.bad}>{localCache.error}</div>
					)}
				</div>
			)}

			<Field label="Импорт из SteamDB" description="Вставьте список вручную — SteamDB парсить нельзя. Понимает «1091501 2461377369266892508», «1091501, 2461377…», «DepotID 1091501 ManifestID 2461377…»." bottomSeparator="standard">
				<textarea
					value={importText}
					onChange={(e) => setImportText(e.currentTarget.value)}
					placeholder={'1091501 2461377369266892508\n1091503 2461377369266892509'}
					style={{
						width: '100%',
						minHeight: '90px',
						fontFamily: 'monospace',
						fontSize: '11px',
						padding: '6px',
						boxSizing: 'border-box',
					}}
				/>
				<div style={{ ...styles.row, marginTop: '6px' }}>
					<DialogButton onClick={runImport} disabled={busy || importBusy || !appid}>
						{importBusy ? 'Разбираю…' : 'Импортировать в план'}
					</DialogButton>
					<DialogButton onClick={() => openExternal(`https://steamdb.info/app/${appid}/depots/`)} disabled={!appid}>
						SteamDB: депо
					</DialogButton>
				</div>
			</Field>

			<Field label="Источники данных" description="Все источники из подборки: что подключено, что требует личного ключа, а что отключено сознательно." bottomSeparator="standard">
				<div style={styles.row}>
					<DialogButton onClick={() => loadSteamCounts(false)} disabled={busy || scBusy || !appid}>
						{scBusy ? 'Грузю…' : 'Загрузить из SteamCounts'}
					</DialogButton>
					<DialogButton onClick={() => loadSteamCounts(true)} disabled={busy || scBusy || !appid}>
						Обновить SteamCounts
					</DialogButton>
					<DialogButton onClick={runProbeSources} disabled={busy || probeBusy}>
						{probeBusy ? 'Проверяю…' : 'Проверить доступность'}
					</DialogButton>
				</div>
			</Field>

			{sc && (
				<div style={styles.card}>
					{sc.ok ? (
						<>
							<div>
								SteamCounts: обновлений {asArray(sc.updates).length} · депо {asArray(sc.depots).length}
							</div>
							{asArray<{ depotid: string; gid: string; size: number; os: string }>(sc.depots).map((d) => (
								<div key={d.depotid} style={{ ...styles.row, ...styles.mono }}>
									<span>
										депо {d.depotid} → {d.gid}
										{d.os ? ` · ${d.os}` : ''}
										{d.size ? ` · ${fmtBytes(d.size)}` : ''}
									</span>
									<Button onClick={() => addToPlan(d.depotid, d.gid)}>в план</Button>
								</div>
							))}
							<div style={styles.mono}>
								{asArray<{ ts: number; branch: string; buildid: string; prev_buildid?: string; depots_changed: number; changelist?: string }>(sc.updates).slice(0, 40).map((u, i) => (
									<div key={`${u.buildid}-${i}`}>
										{new Date(u.ts * 1000).toLocaleString('ru-RU')} · {u.branch} · build {u.buildid}
										{u.prev_buildid ? ` ← ${u.prev_buildid}` : ''} · депо изменено {u.depots_changed}
										{u.changelist ? ` · changelist ${u.changelist}` : ''}
									</div>
								))}
							</div>
							<DialogButton onClick={runAddSteamCountsDb} disabled={!collectEnabled}>
								Сохранить GID SteamCounts в локальную базу
							</DialogButton>
						</>
					) : (
						<div style={styles.bad}>{sc.error}</div>
					)}
				</div>
			)}

			{sourcesProbe && (
				<div style={styles.card}>
					{asArray<{ name: string; url: string; status: number; kind: string }>(sourcesProbe.results).map((r) => (
						<div key={r.name} style={styles.mono}>
							{r.name} — {r.status === 0 ? 'недоступен' : `HTTP ${r.status}`} ·{' '}
							{r.kind === 'json' ? 'JSON' : r.kind === 'html' ? 'HTML' : r.kind === 'need-auth' ? 'нужен ключ/логин' : 'нет ответа'}
						</div>
					))}
				</div>
			)}

			<div style={styles.card}>
				<div style={{ marginBottom: '6px' }}>Полный список источников:</div>
				{SOURCES.map((s) => (
					<div key={s.name} style={{ ...styles.mono, marginBottom: '4px' }}>
						<b>{s.name}</b> — {s.gives} · {s.status}
						{s.url && <Button onClick={() => openExternal(s.url as string)}>открыть</Button>}
					</div>
				))}
			</div>

			<Field label="Свой manifest ID" description="Для манифестов вне веток (SteamDB → Depots → Manifests). GID — 64-битное число, вводится как текст." bottomSeparator="standard">
				<Toggle value={useCustom} onChange={setUseCustom} />
			</Field>

			{useCustom && (
				<div style={styles.card}>
					<div style={styles.row}>
						<TextField label="depotid" value={customDraft.depotid} onChange={(e) => setCustomDraft({ ...customDraft, depotid: e.currentTarget.value.trim() })} style={{ minWidth: '140px' }} />
						<TextField label="manifest GID" value={customDraft.gid} onChange={(e) => setCustomDraft({ ...customDraft, gid: e.currentTarget.value.trim() })} style={{ flex: 1, minWidth: '220px' }} />
						<DialogButton
							onClick={() => {
								if (!customDraft.depotid || !customDraft.gid) return setMessage('нужны и depotid, и GID');
								setCustom([...custom, { ...customDraft }]);
								setCustomDraft({ depotid: '', gid: '' });
							}}
						>
							+ добавить
						</DialogButton>
					</div>
					{custom.map((c, i) => (
						<div key={`${c.depotid}-${c.gid}`} style={{ ...styles.row, ...styles.mono }}>
							<span>депо {c.depotid} → {c.gid}</span>
							<Button onClick={() => setCustom(custom.filter((_, j) => j !== i))}>убрать</Button>
						</div>
					))}
				</div>
			)}

			<Field label="Режим" description="Скачать — безопасный вариант: файлы лягут в steamapps/content. Подменить — бекап текущей версии + перенос файлов на её место." bottomSeparator="standard">
				<Dropdown
					rgOptions={[
						{ data: MODE_DOWNLOAD, label: 'Только скачать' },
						{ data: MODE_SWAP, label: 'Скачать и подменить файлы' },
					]}
					selectedOption={mode === MODE_SWAP ? 1 : 0}
					disabled={notInstalled}
					onChange={(o: any) => setMode(o.data === MODE_SWAP ? MODE_SWAP : MODE_DOWNLOAD)}
				/>
			</Field>

			<Field label="DLC-депо" description="Качать депо дополнений тоже (по умолчанию только базовая игра)" bottomSeparator="standard">
				<Toggle value={includeDlc} onChange={setIncludeDlc} />
			</Field>

			<TextField label="Языки озвучки" value={languages} onChange={(e) => setLanguages(e.currentTarget.value)} description="csv-список: english,russian (учитывается, только если игра не установлена)" />

			{plan && (
				<div style={styles.card}>
					{plan.ok ? (
						<>
							<div>
								<b>{plan.app_name}</b> → {plan.label} · депо {asArray(plan.depots).length} · скачается ~{fmtBytes(plan.total_download)} · на диске ~{fmtBytes(plan.total_size)}
							</div>
							<div style={styles.mono}>
								{asArray<Required<PlanResult>['depots'][number]>(plan.depots)
									.map((d) => `  депо ${d.depotid} · ${d.gid}${d.language ? ` · ${d.language}` : ''}${d.same_as_installed ? ' · уже на этом манифесте' : ''}`)
									.join('\n')}
							</div>
							{asArray(plan.skipped).length > 0 && (
								<div style={{ ...styles.mono, ...styles.warn }}>
									пропущено: {asArray(plan.skipped).map((s: any) => `${s.depotid} (${s.reason})`).join(', ')}
								</div>
							)}
							{asArray<string>(plan.warnings).map((w, i) => (
								<div key={i} style={styles.warn}>⚠ {w}</div>
							))}
						</>
					) : (
						<div style={styles.bad}>план не собран: {plan.error}</div>
					)}
				</div>
			)}

			<div style={styles.row}>
				<DialogButtonPrimary onClick={start} disabled={busy || !plan?.ok}>
					Скачать эту версию
				</DialogButtonPrimary>
				<DialogButton onClick={() => run('отмена', api.cancel)} disabled={busy}>Остановить очередь</DialogButton>
				<DialogButton onClick={() => run('сброс', api.reset)} disabled={busy}>Сбросить</DialogButton>
				{snap?.batch?.content_root && <DialogButton onClick={() => run('папка', () => api.openFolder(snap!.batch!.content_root))}>Открыть папку загрузок</DialogButton>}
				{snap?.all_ready && mode === MODE_SWAP && (
					<DialogButton onClick={() => run('подмена', () => api.applySwap(appid))}>Применить подмену файлов</DialogButton>
				)}
				{asArray(detail?.backups).length > 0 && (
					<DialogButton onClick={() => run('откат', () => api.restoreBackup(appid))}>Вернуть как было</DialogButton>
				)}
			</div>

			{snap?.active_batch && snap.batch && (
				<div style={styles.card}>
					<div>
						<b>{snap.batch.app_name}</b> · {snap.batch.label} · готово {snap.done_count ?? 0}/{snap.batch.depot_count}
						{snap.failed_count ? ` · ошибок ${snap.failed_count}` : ''}
					</div>
					<ProgressBar nProgress={Math.round((snap.progress ?? 0) * 100) / 100} indeterminate={snap.is_running && !snap.total_expected} />
					<div style={styles.mono}>
						{fmtBytes(snap.total_bytes)} из ~{fmtBytes(snap.total_expected)}
					</div>
					{rows.map((r) => (
						<div key={r.depotid} style={{ ...styles.row, ...styles.mono }}>
							<span>депо {r.depotid}</span>
							<span style={r.status === 'failed' ? styles.bad : r.status === 'ready' ? styles.good : undefined}>
								{r.status} {r.expected ? `${fmtBytes(r.bytes)}/${fmtBytes(r.expected)}` : ''} {r.staging ? `( staging ${fmtBytes(r.staging)})` : ''}
							</span>
							{r.error && <span style={styles.bad}>{r.error}</span>}
							{(r.status === 'downloading' || r.status === 'failed') && <Button onClick={() => run('отмечено готово', () => api.markReady(r.depotid))}>готово вручную</Button>}
						</div>
					))}
				</div>
			)}

			{asArray(snap?.log).length > 0 && (
				<div style={{ ...styles.card, ...styles.log }}>
					{asArray<{ t: number; msg: string }>(snap!.log!).map((l, i) => (
						<div key={i}>{fmtTime(l.t)} {l.msg}</div>
					))}
				</div>
			)}

			<Field label="Задержка автообновления" description="Попросить клиента не обновлять игру (app_delay_update, экспериментально)" bottomSeparator="none">
				<Toggle
					value={Boolean(state?.config?.delay_updates)}
					onChange={(v) => {
						setIncludeDlc(includeDlc); // noop-референс, чтобы state не оптимизировался
						run('задержка обновлений', () => api.delayUpdates(appid, v));
					}}
				/>
			</Field>
		</div>
	);
};
