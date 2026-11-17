import { useCallback, useEffect, useState } from 'react';

import { invalidateConsentCache } from '../inject';
import { CONSENT_SCOPE } from '../lib/consts';
import { api, openExternal } from '../lib/rpc';

/**
 * Страница плагина в настройках Millennium: состояние согласия, токен GitHub
 * и ручной сбор по AppID. Основной UI живёт в библиотеке, здесь — управление
 * решением «собирать или нет» и диагностика.
 */

const label: React.CSSProperties = { fontWeight: 600, marginTop: 14, marginBottom: 6 };
const row: React.CSSProperties = { display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' };
const button: React.CSSProperties = {
	padding: '6px 12px',
	borderRadius: 4,
	border: 'none',
	cursor: 'pointer',
	fontWeight: 600,
	background: 'rgba(255,255,255,.14)',
	color: 'inherit',
};
const input: React.CSSProperties = {
	padding: '6px 8px',
	borderRadius: 4,
	border: '1px solid rgba(255,255,255,.25)',
	background: 'rgba(0,0,0,.35)',
	color: 'inherit',
	font: 'inherit',
};
const muted: React.CSSProperties = { opacity: 0.72, fontSize: 12, lineHeight: 1.5 };

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
			setConsent({ consent: String(state?.consent ?? ''), asked: Boolean(state?.asked), shownFor: String(state?.shown_for ?? '') });
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
			invalidateConsentCache();
			await reload();
			setMessage(value === 'reset' ? 'Вопрос будет задан заново при встрече с неизвестной игрой.' : 'Решение сохранено.');
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
			setMessage(res?.ok ? 'Токен сохранён: Issue смогут создаваться автоматически.' : String(res?.error ?? 'не удалось сохранить токен'));
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
				throw new Error(String(issue?.error ?? 'не удалось оформить Issue'));
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
					: 'ещё не спросили — вопрос появится в библиотеке при встрече с игрой, которой нет в базе';

	return (
		<div style={{ fontSize: 13, lineHeight: 1.55, maxWidth: 760 }}>
			<div style={muted}>
				Основной интерфейс плагина — в библиотеке: кнопка Version Rollback в правом нижнем углу и блок в
				свойствах игры («Версии и бета-версии»). Здесь управляется только сбор метаданных и Issue.
			</div>

			<div style={label}>Сбор метаданных о версиях</div>
			<div>Сейчас: {consentText}</div>
			<div style={muted}>
				Собираются только метаданные: AppID, buildid, пары depotid → manifest GID. Без ключей депо, без
				аккаунта, без файлов игры. Вопрос задаётся один раз (отметка поколения: {CONSENT_SCOPE}).
			</div>
			<div style={{ ...row, marginTop: 8 }}>
				<button type="button" style={button} disabled={busy} onClick={() => decide('yes')}>
					Разрешить
				</button>
				<button type="button" style={button} disabled={busy} onClick={() => decide('no')}>
					Запретить
				</button>
				<button type="button" style={button} disabled={busy} onClick={() => decide('reset')}>
					Сбросить вопрос
				</button>
			</div>

			<div style={label}>Issue на GitHub</div>
			<div style={muted}>
				Без токена GitHub не умеет создавать Issue анонимно, поэтому плагин открывает готовую форму —
				отправляете вы сами. С токеном Issue создаётся автоматически.
			</div>
			<div style={{ ...row, marginTop: 8 }}>
				<input
					style={{ ...input, width: 320 }}
					type="password"
					placeholder="ghp_… (личный токен, только public_repo)"
					value={token}
					onChange={(e) => setToken(e.target.value)}
				/>
				<button type="button" style={button} disabled={busy || !token.trim()} onClick={() => saveToken()}>
					Сохранить токен
				</button>
				<button
					type="button"
					style={button}
					onClick={() => openExternal('https://github.com/settings/tokens/new?scopes=public_repo&description=VersionRollback')}
				>
					Создать токен
				</button>
				<span style={muted}>{tokenSet ? 'токен сохранён' : 'токен не задан'}</span>
			</div>

			<div style={label}>Сбор по AppID вручную</div>
			<div style={row}>
				<input style={{ ...input, width: 140 }} placeholder="AppID, напр. 292030" value={appid} onChange={(e) => setAppid(e.target.value)} />
				<button type="button" style={button} disabled={busy} onClick={() => manualIssue()}>
					Собрать и оформить Issue
				</button>
			</div>

			{message && <div style={{ marginTop: 10, color: '#ffd166' }}>{message}</div>}
		</div>
	);
};
