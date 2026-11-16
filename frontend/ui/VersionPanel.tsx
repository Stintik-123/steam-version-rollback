import { Button, DialogButton, DialogButtonPrimary, Dropdown, Field, ProgressBar, TextField, Toggle } from 'millennium';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';

import { api, consoleProbe, openExternal } from '../lib/rpc';
import { asArray, fmtBytes, fmtTime, type AppDetail, type AppState, type PlanResult, type Snapshot } from '../lib/types';

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

export const VersionPanel = ({ appidHint }: { appidHint?: string }) => {
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
	const [message, setMessage] = useState('');
	const [probe, setProbe] = useState<{ ok: boolean; detail: string } | null>(null);
	const timer = useRef<any>(null);

	const selection = useMemo<object>(() => (useCustom ? { custom } : { branch }), [useCustom, custom, branch]);
	const options = useMemo<object>(() => ({ include_dlc: includeDlc, languages: languages.split(/[\s,]+/).filter(Boolean) }), [includeDlc, languages]);

	const fail = (e: unknown) => setMessage(String(e instanceof Error ? e.message : e));

	const loadState = useCallback(async () => {
		const s = await api.getState();
		setState(s);
		if (!s.ok) return fail(s.error ?? 'бэкенд не ответил');
		if (!appid && s.config?.last_appid) setAppid(String(s.config.last_appid));
		if (s.config?.languages) setLanguages(String(s.config.languages));
		setIncludeDlc(Boolean(s.config?.include_dlc));
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
