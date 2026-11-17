import { useEffect, useState } from 'react';

import { CONSENT_KEY, CONSENT_SHOWN_KEY, PLUGIN_VERSION } from '../lib/consts';
import { api } from '../lib/rpc';

/**
 * Компактный баннер с выбором «собирать данные о версиях или нет».
 *
 * Показывается в разделе «Библиотека» Steam: решение пользователя важно
 * показать там, где он видит свои игры, а не в настройках плагина.
 * Сам плагин без согласия не читает ни content_log.txt, ни depotcache.
 */
export const ConsentBanner = ({ onResolved }: { onResolved?: (agreed: boolean) => void }) => {
	const [state, setState] = useState<'loading' | 'ask' | 'done'>('loading');
	const [busy, setBusy] = useState(false);
	const [error, setError] = useState('');

	useEffect(() => {
		api
			.getState()
			.then((s: any) => {
				const shown = String(s?.config?.consent_shown_for ?? '');
				if (shown === PLUGIN_VERSION) {
					setState('done');
					onResolved?.(s?.config?.collect_consent === 'yes');
				} else {
					setState('ask');
				}
			})
			.catch(() => setState('ask'));
	}, []);

	const answer = async (yes: boolean) => {
		setBusy(true);
		setError('');
		try {
			await api.setSetting(CONSENT_KEY, yes ? 'yes' : 'no');
			await api.setSetting(CONSENT_SHOWN_KEY, PLUGIN_VERSION);
			setState('done');
			onResolved?.(yes);
		} catch (e) {
			setError(String(e instanceof Error ? e.message : e));
		} finally {
			setBusy(false);
		}
	};

	if (state !== 'ask') return null;

	const box: React.CSSProperties = {
		width: '340px',
		padding: '12px 14px',
		borderRadius: '6px',
		background: 'linear-gradient(180deg, rgba(23,26,33,.98), rgba(12,14,18,.98))',
		border: '1px solid rgba(255,209,102,.45)',
		boxShadow: '0 10px 34px rgba(0,0,0,.55)',
		color: '#e6e6e6',
		fontSize: '13px',
		lineHeight: '1.45',
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
		<div style={box} role="dialog" aria-label="Выбор сбора данных">
			<div style={{ fontWeight: '700', marginBottom: '6px', color: '#ffd166' }}>
				Крупное обновление Version Rollback {PLUGIN_VERSION}
			</div>
			<div style={{ marginBottom: '8px' }}>
				Плагин умеет собирать версии по максимуму: локальные кэши Steam (content_log.txt, depotcache,
				appmanifest), сборки и манифесты из SteamRaw, текущие GID из SteamCounts. Это только метаданные:
				AppID, buildid, depotid и manifest GID — без ключей депо и без обхода прав.
			</div>
			<div style={{ marginBottom: '10px' }}>
				<b>Собирать данные о версиях с вашего компьютера?</b> Если «да» — плагин соберёт их в локальную
				базу и покажет отчёт, который можно отправить в Issue проекта на GitHub (отправляете его вы сами).
				Если «нет» — плагин ничего не читает и никуда не отправляет.
			</div>
			{error && <div style={{ color: '#ff6b6b', marginBottom: '6px' }}>{error}</div>}
			<div style={{ display: 'flex', gap: '8px' }}>
				<button
					type="button"
					style={{ ...button, background: '#1a9fff', color: '#fff' }}
					disabled={busy}
					onClick={() => answer(true)}
				>
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
