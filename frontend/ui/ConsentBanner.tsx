import { useState } from 'react';

import { api, openExternal } from '../lib/rpc';
import { steamButton, steamTheme } from '../lib/steamTheme';

/**
 * Карточка согласия на сбор метаданных — в стиле штатных баннеров Steam
 * (как «Anonymous framerate data» / «Would you like to revise your review?»).
 *
 * Вставляется в поток страницы библиотеки между блоком обновления и секцией
 * «Активность». Один вопрос за всё время.
 *
 * «Да» → сбор метаданных + открытие браузера с готовым Issue на GitHub
 * (или авто-создание при наличии токена). «Нет» → ничего не читаем и не шлём.
 */
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

	const answer = async (yes: boolean) => {
		if (busy || done) return;
		setBusy(true);
		setError('');
		setStatus('');
		try {
			await api.setConsent(yes ? 'yes' : 'no');
			if (!yes) {
				setStatus('Принято. Плагин ничего не собирает и никуда не отправляет.');
				setDone(true);
				onDone?.(false);
				return;
			}
			setStatus('Собираю метаданные по игре…');
			const collected = await api.collectApp(appid);
			if (collected && collected.ok === false) {
				setError(String(collected.error ?? 'сбор не удался'));
				setDone(true);
				onDone?.(true);
				return;
			}
			setStatus('Открываю Issue на GitHub…');
			const issue = await api.submitAppIssue(appid);
			if (issue?.number) {
				setStatus(`Готово: создан Issue #${issue.number}. Спасибо!`);
			} else if (issue?.url) {
				openExternal(issue.url);
				setStatus('Форма Issue открылась в браузере — проверьте текст и нажмите Create. Отправляете только вы.');
			} else {
				// Fallback: прямая ссылка на issues/new, если бэкенд не вернул url
				const fallback =
					'https://github.com/Stintik-123/steam-version-rollback/issues/new?title=' +
					encodeURIComponent(`Version data for AppID ${appid}`) +
					'&body=' +
					encodeURIComponent(
						`## AppID\n${appid}\n\n## Notes\n(metadata will be filled by the plugin when available)\n`,
					);
				openExternal(fallback);
				setStatus('Открыл форму Issue на GitHub. Заполните и отправьте сами.');
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
		background: steamTheme.panel, // #1b2838
		border: `1px solid ${steamTheme.border}`, // #2a475e
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
		<div style={box} role="dialog" aria-label="Сбор метаданных о версиях">
			<div style={titleStyle}>Version Rollback: сбор метаданных о версиях</div>
			<div style={{ marginBottom: 8 }}>
				Игры <b>{appName ? `${appName} ` : ''}(AppID {appid})</b> ещё нет в общей базе версий.
				Разрешаете собрать по ней только метаданные — AppID, buildid и пары depotid → manifest GID
				(без ключей депо, без аккаунта, без файлов игры) — и отправить в Issue проекта?
			</div>
			<div style={mutedStyle}>
				«Да» — сбор и открытие формы Issue на GitHub (отправляете вы сами; с токеном Issue создаётся автоматически).
				«Нет» — плагин не читает локальные кэши Steam и ничего не отправляет. Вопрос больше не появится.
			</div>
			{status && (
				<div style={{ marginBottom: 8, color: steamTheme.ok, fontSize: 12 }}>{status}</div>
			)}
			{error && (
				<div style={{ marginBottom: 8, color: steamTheme.err, fontSize: 12 }}>{error}</div>
			)}
			{!done && (
				<div style={btnRow}>
					<button
						type="button"
						style={{ ...steamButton(true), minWidth: 90 }}
						disabled={busy}
						onClick={() => answer(true)}
					>
						{busy ? '…' : 'Да'}
					</button>
					<button
						type="button"
						style={{ ...steamButton(false), minWidth: 90 }}
						disabled={busy}
						onClick={() => answer(false)}
					>
						Нет, спасибо
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
						onClick={() =>
							openExternal(
								'https://github.com/Stintik-123/steam-version-rollback#локальный-сбор-данных-и-отправка-в-issue',
							)
						}
					>
						Подробнее
					</button>
				</div>
			)}
		</div>
	);
};
