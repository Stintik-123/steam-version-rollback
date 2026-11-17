import { useCallback, useEffect, useState } from 'react';

import { CONSENT_SCOPE } from '../lib/consts';
import { api, openExternal } from '../lib/rpc';
import { steamButton, steamTheme } from '../lib/steamTheme';

/**
 * Чистая страница настроек Millennium.
 * Убраны лишние блоки (пробы источников, массовый сбор, длинные списки).
 * Оставлено только нужное обычному пользователю:
 *  - текущее решение по сбору
 *  - смена решения / сброс вопроса
 *  - опциональный GitHub-токен
 *  - разовый ручной сбор по AppID
 */

const label: React.CSSProperties = {
	fontWeight: 600,
	marginTop: 16,
	marginBottom: 6,
	color: steamTheme.text,
	fontSize: 13,
};
const row: React.CSSProperties = { display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' };
const button: React.CSSProperties = steamButton(false);
const input: React.CSSProperties = {
	padding: '6px 10px',
	borderRadius: 3
	border: `1px solid ${steamTheme.border}`,
	background: steamTheme.panel,
	color: steamTheme.text,
	font: 'inherit',
};
const muted: React.CSSProperties = { color: steamTheme.muted, fontSize: 12, lineHeight: 1.5 };

type ConsentState = { consent: string; asked: boolean; shownFor: string };

export const SettingsPanel = () => {
	const [consent, setConsent] = useState<ConsentState | null>(null);
	const [message, setMessage] = useState('');
	const [token, setToken] = useState('');
	const [tokenSet, setTokenSet] = useState(false);
	const [appid, setAppid] = useState('');
	const [busy, setBusy] = useState(false);

	const reload = useCallback(async () => {
		try {
			const state = await api.getConsent();
			setConsent({
				consent: String(state?.consent ?? ''),
				asked: Boolean(state?.asked),
				shownFor: String(state?.shown_for ?? ''),
			});
			setTokenSet(Boolean(state?.github_token_set));
		} catch (e) {
			setMessage('Бэкенд недоступен: ' + String(e instanceof Error ? e.message : e));
		}
	}, []);

	useEffect(() => {
		void reload();
	}, [reload]);

	const decide = async (value: 'yes' | 'no' | 'reset') => {
		setBusy(true);
		try {
			if (value === 'reset') {
				await api.setSetting('collect_consent', '');
				await api.setSetting('consent_shown_for', '');
			} else {
				await api.setConsent(value);
			}
			// сброс кэша в inject (если экспортирован)
			try {
				(window as any).dispatchEvent?.(new Event('vrb-consent-changed'));
			} catch {
				/* ok */
			}
			await reload();
			setMessage(
				value === 'reset'
					? 'Вопрос будет задан заново при встрече с неизвестной игрой.'
					: 'Решение сохранено.',
			);
		} catch (e) {
			setMessage(String(e instanceof Error ? e.message : e));
		} finally {
			setBusy(false);
		}
	};

	const saveToken = async () => {
		setBusy(true);
		try {
			const res = await api.setGithubToken(token.trim());
			setTokenSet(Boolean(res?.ok));
			setToken('');
			setMessage(
				res?.ok
					? 'Токен сохранён: Issue смогут создаваться автоматически.'
					: String(res?.error ?? 'не удалось сохранить токен'),
			);
			await reload();
		} catch (e) {
			setMessage(String(e instanceof Error ? e.message : e));
		} finally {
			setBusy(false);
		}
	};

	const manualIssue = async () => {
		const id = appid.trim();
		if (!/^\d{1,10}$/.test(id)) {
			setMessage('Введите AppID числом, например 292030.');
			return;
		}
		setBusy(true);
		try {
			const collected = await api.collectApp(id);
			if (collected?.ok === false) throw new Error(String(collected.error ?? 'сбор не удался'));
			const issue = await api.submitAppIssue(id);
			if (issue?.number) {
				setMessage(`Создан Issue #${issue.number}: ${issue.url ?? ''}`);
			} else if (issue?.url) {
				openExternal(issue.url);
				setMessage('Форма Issue открыта в браузере — отправьте её вы сами.');
			} else {
				const fallback =
					'https://github.com/Stintik-123/steam-version-rollback/issues/new?title=' +
					encodeURIComponent(`Version data for AppID ${id}`);
				openExternal(fallback);
				setMessage('Открыл форму Issue на GitHub.');
			}
		} catch (e) {
			setMessage(String(e instanceof Error ? e.message : e));
		} finally {
			setBusy(false);
		}
	};

	const consentText =
		consent === null
			? 'уточняется…'
			: consent.consent === 'yes'
				? 'разрешено (собирать и оформлять Issue)'
				: consent.consent === 'no'
					? 'запрещено (плагин ничего не читает и не отправляет)'
					: 'ещё не спрашивали — вопрос появится в библиотеке при игре, которой нет в базе';

	return (
		<div
			style={{
				fontSize: 13,
				lineHeight: 1.55,
				maxWidth: 640,
				padding: '14px 16px',
				borderRadius: 3,
				background: steamTheme.panelAlt,
				border: `1px solid ${steamTheme.border}`,
				color: steamTheme.text,
				fontFamily: '"Motiva Sans", Arial, Helvetica, sans-serif',
			}}
		>
			<div style={muted}>
				Основной интерфейс — в свойствах игры («Версии и бета-версии»). Здесь только согласие на сбор
				метаданных и опциональный токен GitHub.
			</div>


			<div style={label}>Сбор метаданных о версиях</div>
			<div>Сейчас: <b>{consentText}</b></div>
			<div style={{ ...muted, marginTop: 4 }}>
				Собираются только AppID, buildid, depotid → manifest GID. Без ключей депо, без аккаунта, без
				файлов игры. Вопрос задаётся один раз (поколение: {CONSENT_SCOPE}).
			</div>
			<div style={{ ...row, marginTop: 10 }}>
				<button type="button" style={steamButton(true)} disabled={busy} onClick={() => decide('yes')}>
					Разрешить
				</button>
				<button type="button" style={button} disabled={busy} onClick={() => decide('no')}>
					Запретить
				</button>
				<button type="button" style={button} disabled={busy} onClick={() => decide('reset')}>
					Сбросить вопрос
				</button>
			</div>

			<div style={label}>Issue на GitHub (необязательно)</div>
			<div style={muted}>
				Без токена плагин открывает готовую форму Issue — отправляете вы сами. С токеном Issue
				создаётся автоматически. В будущем планируется Cloudflare Workers → автопуш в репозиторий.
			</div>
			<div style={{ ...row, marginTop: 8 }}>
				<input
					style={{ ...input, width: 280 }}
					type="password"
					placeholder="ghp_… (только public_repo)"
					value={token}
					onChange={(e) => setToken(e.target.value)}
				/>
				<button type="button" style={button} disabled={busy || !token.trim()} onClick={() => saveToken()}>
					Сохранить
				</button>
				<button
					type="button"
					style={{ ...button, color: steamTheme.accent }}
					onClick={() =>
						openExternal(
							'https://github.com/settings/tokens/new?scopes=public_repo&description=VersionRollback',
						)
					}
				>
					Создать токен
				</button>
				<span style={muted}>{tokenSet ? 'токен сохранён' : 'токен не задан'}</span>
			</div>

			<div style={label}>Сбор по одной игре</div>
			<div style={row}>
				<input
					style={{ ...input, width: 140 }}
					placeholder="AppID"
					value={appid}
					onChange={(e) => setAppid(e.target.value)}
				/>
				<button type="button" style={button} disabled={busy} onClick={() => manualIssue()}>
					Собрать и открыть Issue
				</button>
			</div>

			{message && (
				<div style={{ marginTop: 12, color: steamTheme.accent, fontSize: 12 }}>{message}</div>
			)}
		</div>
	);
};
