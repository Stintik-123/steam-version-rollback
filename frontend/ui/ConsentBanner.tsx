import { useState } from 'react';

import { api, openExternal } from '../lib/rpc';
import { steamButton, steamTheme } from '../lib/steamTheme';

/**
 * Карточка согласия на сбор метаданных — в стиле штатных баннеров Steam.
 *
 * Вставляется на странице игры в библиотеке сразу после поля «Расскажите об этой
 * игре друзьям…» и перед лентой с датами. Один вопрос за всё время.
 *
 * «Да» → сбор метаданных + открытие браузера с готовым Issue на GitHub
 * (или авто-создание при наличии токена). «Нет» → ничего не читаем и не шлём.
 */

const REPO_URL = 'https://github.com/Stintik-123/steam-version-rollback';

type Lang = 'ru' | 'en';

/** Язык интерфейса Steam, если клиент его отдаёт; иначе язык браузера. */
export const detectLang = (): Lang => {
	try {
		const sc = (globalThis as unknown as { SteamClient?: { Settings?: { GetCurrentLanguage?: () => string } } }).SteamClient;
		const steamLang = sc?.Settings?.GetCurrentLanguage?.();
		if (typeof steamLang === 'string' && steamLang) return steamLang.toLowerCase().startsWith('russian') || steamLang.toLowerCase().startsWith('ru') ? 'ru' : 'en';
	} catch {
		// клиент не отдал язык — берём браузерный
	}
	return /^ru/i.test(navigator.language ?? '') ? 'ru' : 'en';
};

const T = {
	ru: {
		title: 'Version Rollback: сбор метаданных о версиях',
		ask: (name: string, appid: string) =>
			`Игры ${name}(AppID ${appid}) ещё нет в общей базе версий. Разрешаете собрать по ней только метаданные — AppID, buildid и пары depotid → manifest GID (без ключей депо, без аккаунта, без файлов игры) — и отправить в Issue проекта?`,
		help: '«Да» — сбор и открытие формы Issue на GitHub (отправляете вы сами; с токеном Issue создаётся автоматически). «Нет» — плагин не читает локальные кэши Steam и ничего не отправляет. Вопрос больше не появится.',
		yes: 'Да',
		no: 'Нет, спасибо',
		more: 'Подробнее',
		collecting: 'Собираю метаданные по игре…',
		opening: 'Открываю Issue на GitHub…',
		created: (n: string) => `Готово: создан Issue #${n}. Спасибо!`,
		opened: 'Форма Issue открылась в браузере — проверьте текст и нажмите Create. Отправляете только вы.',
		fallback: 'Открыл форму Issue на GitHub. Заполните и отправьте сами.',
		declined: 'Принято. Плагин ничего не собирает и никуда не отправляет.',
		aria: 'Сбор метаданных о версиях',
	},
	en: {
		title: 'Version Rollback: version metadata collection',
		ask: (name: string, appid: string) =>
			`${name}(AppID ${appid}) is not in the shared version database yet. May we collect only metadata for it — AppID, buildid and depotid → manifest GID pairs (no depot keys, no account, no game files) — and send it to the project's Issue tracker?`,
		help: 'Yes — collect and open a GitHub Issue form (you submit it yourself; with a token the Issue is created automatically). No — the plugin does not read local Steam caches and sends nothing. The question will not appear again.',
		yes: 'Yes',
		no: 'No, thanks',
		more: 'Learn more',
		collecting: 'Collecting metadata for this game…',
		opening: 'Opening a GitHub Issue…',
		created: (n: string) => `Done: Issue #${n} created. Thank you!`,
		opened: 'The Issue form opened in your browser — check the text and press Create. Only you submit it.',
		fallback: 'Opened the GitHub Issue form. Fill it in and submit it yourself.',
		declined: 'Noted. The plugin collects nothing and sends nothing.',
		aria: 'Version metadata collection',
	},
} as const;

export const ConsentCard = ({
	appid,
	appName,
	onDone,
}: {
	appid: string;
	appName?: string;
	onDone?: (agreed: boolean) => void;
}) => {
	const [busy, setBusy] = useState(false);
	const [status, setStatus] = useState('');
	const [error, setError] = useState('');
	const [done, setDone] = useState(false);
	const t = T[detectLang()];

	const answer = async (yes: boolean) => {
		if (busy || done) return;
		setBusy(true);
		setError('');
		setStatus('');
		try {
			await api.setConsent(yes ? 'yes' : 'no');
			if (!yes) {
				setStatus(t.declined);
				setDone(true);
				onDone?.(false);
				return;
			}
			setStatus(t.collecting);
			const collected = await api.collectApp(appid);
			if (collected && collected.ok === false) {
				setError(String(collected.error ?? 'сбор не удался'));
				setDone(true);
				onDone?.(true);
				return;
			}
			setStatus(t.opening);
			const issue = await api.submitAppIssue(appid);
			if (issue?.number) {
				setStatus(t.created(String(issue.number)));
			} else if (issue?.url) {
				openExternal(issue.url);
				setStatus(t.opened);
			} else {
				// Запасной вариант: пустая форма Issue, если бэкенд не вернул ссылку.
				const fallback =
					`${REPO_URL}/issues/new?title=` +
					encodeURIComponent(`Version data for AppID ${appid}`) +
					'&body=' +
					encodeURIComponent(`## AppID\n${appid}\n\n## Notes\n(metadata will be filled by the plugin when available)\n`);
				openExternal(fallback);
				setStatus(t.fallback);
			}
			setDone(true);
			onDone?.(true);
		} catch (e) {
			setError(String(e instanceof Error ? e.message : e));
			setDone(true);
			onDone?.(yes);
		} finally {
			setBusy(false);
		}
	};

	// Внешний вид максимально близкий к баннеру Steam «Anonymous framerate data»
	const box: React.CSSProperties = {
		width: '100%',
		boxSizing: 'border-box',
		padding: '14px 16px',
		borderRadius: '3px',
		background: steamTheme.panel,
		border: `1px solid ${steamTheme.border}`,
		color: steamTheme.text,
		fontSize: '13px',
		lineHeight: 1.45,
		fontFamily: '"Motiva Sans", Arial, Helvetica, sans-serif',
	};

	const titleStyle: React.CSSProperties = {
		fontWeight: 700,
		fontSize: '14px',
		marginBottom: 6,
		color: steamTheme.text,
	};

	const mutedStyle: React.CSSProperties = {
		color: steamTheme.muted,
		fontSize: '12px',
		marginBottom: 12,
		lineHeight: 1.4,
	};

	const btnRow: React.CSSProperties = {
		display: 'flex',
		gap: 8,
		justifyContent: 'flex-end',
		flexWrap: 'wrap',
	};

	return (
		<div style={box} role="dialog" aria-label={t.aria}>
			<div style={titleStyle}>{t.title}</div>
			<div style={{ marginBottom: 8 }}>{t.ask(appName ? `${appName} ` : '', appid)}</div>
			<div style={mutedStyle}>{t.help}</div>
			{status && <div style={{ marginBottom: 8, color: steamTheme.ok, fontSize: 12 }}>{status}</div>}
			{error && <div style={{ marginBottom: 8, color: steamTheme.err, fontSize: 12 }}>{error}</div>}
			{!done && (
				<div style={btnRow}>
					<button type="button" style={{ ...steamButton(true), minWidth: 90 }} disabled={busy} onClick={() => answer(true)}>
						{busy ? '…' : t.yes}
					</button>
					<button type="button" style={{ ...steamButton(false), minWidth: 90 }} disabled={busy} onClick={() => answer(false)}>
						{t.no}
					</button>
					<button
						type="button"
						style={{
							...steamButton(false),
							background: 'transparent',
							border: 'none',
							color: steamTheme.accent,
							fontWeight: 500,
							minWidth: 'auto',
							padding: '7px 10px',
						}}
						disabled={busy}
						onClick={() => openExternal(REPO_URL)}
					>
						{t.more}
					</button>
				</div>
			)}
		</div>
	);
};
