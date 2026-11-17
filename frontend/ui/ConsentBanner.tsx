import { useState } from 'react';

import { api, openExternal } from '../lib/rpc';

/**
 * Карточка единственного вопроса: «разрешаете собирать метаданные о версиях
 * игр, которых ещё нет в общей базе, и отправлять их в Issue проекта?».
 *
 * Показывается ОДИН раз за всё время (решение хранится в настройках
 * Millennium: collect_consent + consent_shown_for) и только когда плагин
 * реально встретил игру, которой нет в базе версий — то есть когда сбор
 * имеет смысл. Внизу окна, поверх страницы библиотеки.
 *
 * При «да»: метаданные собираются по этой игре и сразу оформляются в Issue:
 * с токеном — создаётся автоматически, без токена — открывается готовая
 * форма на GitHub (отправка одним нажатием, ничего не уходит само).
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

	const answer = async (yes: boolean) => {
		setBusy(true);
		setError('');
		setStatus('');
		try {
			await api.setConsent(yes ? 'yes' : 'no');
			if (!yes) {
				setStatus('Принято. Плагин ничего не собирает и никуда не отправляет.');
				onDone?.(false);
				return;
			}
			setStatus('Собираю метаданные по игре…');
			const collected = await api.collectApp(appid);
			if (collected && collected.ok === false) {
				setError(String(collected.error ?? 'сбор не удался'));
				onDone?.(true);
				return;
			}
			setStatus('Оформляю Issue на GitHub…');
			const issue = await api.submitAppIssue(appid);
			if (issue?.number) {
				setStatus(`Готово: создан Issue #${issue.number}. Спасибо!`);
			} else if (issue?.url) {
				openExternal(issue.url);
				setStatus('Готово: форма Issue открылась в браузере — проверьте текст и нажмите «Create». Отправляете только вы.');
			} else {
				setError(String(issue?.error ?? 'не удалось оформить Issue'));
			}
			onDone?.(true);
		} catch (e) {
			setError(String(e instanceof Error ? e.message : e));
			onDone?.(yes);
		} finally {
			setBusy(false);
		}
	};

	const box: React.CSSProperties = {
		width: '360px',
		padding: '12px 14px',
		borderRadius: '6px',
		background: 'linear-gradient(180deg, rgba(23,26,33,.98), rgba(12,14,18,.98))',
		border: '1px solid rgba(255,209,102,.45)',
		boxShadow: '0 10px 34px rgba(0,0,0,.55)',
		color: '#e6e6e6',
		fontSize: '13px',
		lineHeight: 1.45,
	};

	const button: React.CSSProperties = {
		flex: '1 1 0',
		padding: '7px 10px',
		borderRadius: '4px',
		border: 'none',
		cursor: busy ? 'default' : 'pointer',
		fontWeight: '600',
	};

	return (
		<div style={box} role="dialog" aria-label="Сбор метаданных о версиях">
			<div style={{ fontWeight: 700, marginBottom: 6, color: '#ffd166' }}>Version Rollback: вопрос один раз</div>
			<div style={{ marginBottom: 8 }}>
				Игры <b>{appName ? `${appName} ` : ''}(AppID {appid})</b> ещё нет в общей базе версий плагина. Разрешаете
				собрать по ней метаданные — только AppID, buildid и пары depotid → manifest GID (без ключей депо, без
				аккаунта, без файлов игры) — и отправить их в Issue проекта, чтобы версия появилась в базе?
			</div>
			<div style={{ marginBottom: 10, opacity: 0.85, fontSize: 12 }}>
				«Да» — сбор и Issue по этой игре (без токена GitHub откроется готовая форма: отправляете вы сами).
				«Нет» — плагин не читает локальные кэши Steam и ничего не отправляет. Переспрашивать не будем.
			</div>
			{status && <div style={{ marginBottom: 6, color: '#8fd18f' }}>{status}</div>}
			{error && <div style={{ marginBottom: 6, color: '#ff6b6b' }}>{error}</div>}
			<div style={{ display: 'flex', gap: 8 }}>
				<button type="button" style={{ ...button, background: '#1a9fff', color: '#fff' }} disabled={busy} onClick={() => answer(true)}>
					Да, собирать
				</button>
				<button
					type="button"
					style={{ ...button, background: 'rgba(255,255,255,.12)', color: '#e6e6e6' }}
					disabled={busy}
					onClick={() => answer(false)}
				>
					Нет, не собирать
				</button>
			</div>
		</div>
	);
};
