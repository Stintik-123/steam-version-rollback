import { useEffect, useRef, useState } from 'react';

import { getReactInstance } from 'millennium';

import { api } from '../lib/rpc';
import { ConsentCard } from './ConsentBanner';
import { VersionPanel } from './VersionPanel';

/**
 * Видимый слой плагина в НАСТОЯЩЕМ окне Steam.
 *
 * Почему так: бандл плагина Millennium выполняется в SharedJSContext —
 * служебном скрытом окне Steam (ширина 1 px). DOM, вставленный туда через
 * inject.tsx, пользователю не виден: карточка «исчезала», кнопка в углу
 * библиотеки тоже не появлялась.
 *
 * Решение: глобальный компонент Millennium (routerHook.addGlobalComponent)
 * рендерится в настоящем окне Steam. Здесь мы:
 *   1) показываем кнопку «Version Rollback» в правом нижнем углу;
 *   2) показываем карточку вопроса о сборе — между блоком «Небольшое обновление
 *      или список изменений» и секцией «Активность» на странице игры.
 */

/** Заголовок секции «Активность» — карточка встаёт прямо над ним. */
const ACTIVITY_MARKERS = ['Активность', 'Activity', 'Aktivität', 'Activité'];

const findTextElement = (markers: string[]): HTMLElement | null => {
	if (!document.body) return null;
	const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
	let node: Node | null = walker.nextNode();
	while (node) {
		const text = (node.nodeValue ?? '').trim();
		if (text && text.length < 90 && markers.includes(text)) {
			const parent = node.parentElement;
			if (parent) return parent;
		}
		node = walker.nextNode();
	}
	return null;
};

/** AppID страницы игры: из URL, иначе из React-пропсов контейнера. */
const findAppId = (): string | undefined => {
	const fromUrl = location.href.match(/(?:#|\/)(?:app|details)\/(\d{3,})/);
	if (fromUrl) return fromUrl[1];
	try {
		const anchor =
			document.querySelector('[class*="appdetailsoverview"]') ??
			document.querySelector('[class*="libraryappdetails"]') ??
			document.querySelector('[class*="appdetailsgamepad"]');
		if (!anchor) return undefined;
		let fiber = getReactInstance(anchor) as any;
		for (let depth = 0; fiber && depth < 30; depth++) {
			const props = fiber.memoizedProps ?? {};
			for (const key of ['appid', 'appId', 'unAppID', 'nAppID', 'app_id']) {
				const value = props[key];
				if (typeof value === 'number' && Number.isFinite(value) && value > 0) return String(value);
				if (typeof value === 'string' && /^\d{3,}$/.test(value)) return value;
			}
			fiber = fiber.return;
		}
	} catch {
		/* без React-дерева — вернём undefined */
	}
	return undefined;
};

const dockButtonCss: React.CSSProperties = {
	padding: '10px 14px',
	borderRadius: 8,
	border: '1px solid rgba(255,255,255,.18)',
	background: 'rgba(27,40,56,.94)',
	color: '#c7d5e0',
	font: '13px "Motiva Sans",Arial,sans-serif',
	cursor: 'pointer',
	boxShadow: '0 6px 24px rgba(0,0,0,.45)',
};

const dockCss: React.CSSProperties = {
	position: 'fixed',
	right: 24,
	bottom: 24,
	zIndex: 2147483646,
	display: 'flex',
	flexDirection: 'column',
	alignItems: 'flex-end',
	gap: 8,
};

export const GlobalCard = () => {
	const cardRef = useRef<HTMLDivElement | null>(null);
	const [appid, setAppid] = useState<string | null>(null);
	const [placed, setPlaced] = useState(false);

	/* Диагностика: в каком окне/документе живёт глобальный компонент. */
	useEffect(() => {
		const info = {
			title: document.title,
			w: window.innerWidth,
			h: window.innerHeight,
			hasActivity: (document.body?.innerText ?? '').includes('Активность'),
			hasUpdate: (document.body?.innerText ?? '').includes('Небольшое обновление'),
			steamClient: typeof (globalThis as any).SteamClient,
			appid: findAppId() ?? null,
		};
		api.debugNote('globalcard ctx ' + JSON.stringify(info)).catch((): void => undefined);
	}, []);

	/* Ищем игру и решаем, показывать ли вопрос. */
	useEffect(() => {
		let cancelled = false;

		const decide = async (): Promise<void> => {
			try {
				const state = await api.getConsent();
				if (cancelled || state?.asked) return; // вопрос уже задавали
				const id = findAppId();
				if (!id) return;
				const known = await api.appKnown(id);
				if (cancelled || known?.known) return; // игра уже в базе
				setAppid(id);
			} catch {
				/* бэкенд недоступен — попробуем при следующем изменении DOM */
			}
		};

		void decide();

		const observer = new MutationObserver(() => {
			void decide();
		});
		if (document.body) {
			observer.observe(document.body, { childList: true, subtree: true, characterData: true });
		}
		return () => {
			cancelled = true;
			observer.disconnect();
		};
	}, []);

	/* Переносим карточку между «Небольшое обновление» и «Активность». */
	useEffect(() => {
		if (!appid || !cardRef.current || placed) return;
		const node = cardRef.current;
		let tries = 0;
		const tryPlace = (): void => {
			const activity = findTextElement(ACTIVITY_MARKERS);
			if (activity && activity.parentElement) {
				activity.parentElement.insertBefore(node, activity);
				setPlaced(true);
				api.debugNote('card placed before activity, appid=' + appid).catch((): void => undefined);
				return;
			}
			tries += 1;
			if (tries < 60) {
				window.setTimeout(tryPlace, 500);
				return;
			}
			api.debugNote('anchor not found (activity), appid=' + appid).catch((): void => undefined);
		};
		tryPlace();
	}, [appid, placed]);

	if (!appid) return null;

	return (
		<div ref={cardRef} id="version-rollback-consent-card" style={{ margin: '12px 0' }}>
			<ConsentCard appid={appid} onDone={() => setAppid(null)} />
		</div>
	);
};

/** Кнопка в углу библиотеки — рендерится в настоящем окне (SharedJSContext не годится). */
export const GlobalDock = () => {
	const [open, setOpen] = useState(false);
	return (
		<div style={dockCss}>
			{open && (
				<div
					style={{
						display: 'flex',
						flexDirection: 'column',
						width: 'min(560px,calc(100vw - 48px))',
						maxHeight: 'calc(100vh - 120px)',
						borderRadius: 10,
						border: '1px solid rgba(255,255,255,.16)',
						background: 'rgba(22,32,45,.98)',
						color: '#c7d5e0',
						boxShadow: '0 12px 40px rgba(0,0,0,.55)',
						font: '13px "Motiva Sans",Arial,sans-serif',
						overflow: 'hidden',
					}}
				>
					<div
						style={{
							display: 'flex',
							justifyContent: 'space-between',
							alignItems: 'center',
							padding: '10px 14px',
							borderBottom: '1px solid rgba(255,255,255,.1)',
							fontWeight: 600,
						}}
					>
						<span>Version Rollback</span>
						<button
							type="button"
							style={{ background: 'none', border: 'none', color: '#8f98a0', fontSize: 18, cursor: 'pointer' }}
							onClick={() => setOpen(false)}
						>
							×
						</button>
					</div>
					<div style={{ overflowY: 'auto', padding: '12px 14px 16px' }}>
						<VersionPanel />
					</div>
				</div>
			)}
			<button type="button" style={dockButtonCss} onClick={() => setOpen((v) => !v)} title="Выбрать версию игры">
				Version Rollback
			</button>
		</div>
	);
};
