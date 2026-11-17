import { useEffect, useRef, useState } from 'react';

import { getReactInstance } from 'millennium';

import { api } from '../lib/rpc';
import { currentRoute, onRoute, startRouteTracking } from '../lib/route';
import { ConsentCard } from './ConsentBanner';

/**
 * Единственный механизм показа карточки согласия.
 *
 * Раньше карточку пытались вставить и inject.tsx, и GlobalCard — конфликт по
 * одному id, хрупкий поиск якорей, AppID часто не находился. Теперь:
 *  - только этот компонент;
 *  - AppID из URL / маршрута Steam, React Fiber — запасной путь;
 *  - якоря ищем по подстроке (не только точное совпадение);
 *  - MutationObserver держит попытки, пока страница не дорисуется;
 *  - диагностика в api.debugNote на каждом шаге.
 */

const CONSENT_ID = 'version-rollback-consent-card';

/** Подстроки заголовка «Активность» (регистр не важен). */
const ACTIVITY_SUB = ['активность', 'activity', 'aktivität', 'activite', 'activité'];
/** Подстроки блока обновления / featured. */
const UPDATE_SUB = [
	'небольшое обновление',
	'minor update',
	'small update',
	'patch notes',
	'список изменений',
	'change list',
	'featured',
];

const log = (msg: string) => {
	console.info('[Version Rollback][consent]', msg);
	api.debugNote('consent ' + msg).catch((): void => undefined);
};

const findTextBySubstrings = (subs: string[]): HTMLElement | null => {
	if (!document.body) return null;
	const lowerSubs = subs.map((s) => s.toLowerCase());
	const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
	let node: Node | null = walker.nextNode();
	while (node) {
		const text = (node.nodeValue ?? '').trim();
		if (text && text.length < 100) {
			const low = text.toLowerCase();
			if (lowerSubs.some((s) => low.includes(s))) {
				const parent = node.parentElement;
				if (parent) return parent;
			}
		}
		node = walker.nextNode();
	}
	return null;
};

/** AppID: URL → route → React props контейнера игры. */
const findAppId = (): string | undefined => {
	const href = String(location.href ?? '') + ' ' + String(location.hash ?? '');
	const fromUrl =
		href.match(/(?:#|\/)(?:app|details|library\/app)\/(\d{3,})/i) ??
		href.match(/\/app\/(\d{3,})/);
	if (fromUrl) return fromUrl[1];

	const route = currentRoute();
	if (route.appid) return route.appid;

	try {
		const anchor =
			document.querySelector('[class*="appdetailsoverview"]') ??
			document.querySelector('[class*="libraryappdetails"]') ??
			document.querySelector('[class*="AppDetails"]') ??
			document.querySelector('[class*="appdetailsgamepad"]') ??
			document.querySelector('[class*="appdetails_"]');
		if (!anchor) return undefined;
		let fiber = getReactInstance(anchor) as any;
		for (let depth = 0; fiber && depth < 40; depth++) {
			const props = fiber.memoizedProps ?? {};
			for (const key of ['appid', 'appId', 'unAppID', 'nAppID', 'app_id', 'id']) {
				const value = props[key];
				if (typeof value === 'number' && Number.isFinite(value) && value > 0) return String(value);
				if (typeof value === 'string' && /^\d{3,}$/.test(value)) return value;
			}
			fiber = fiber.return;
		}
	} catch {
		/* без React-дерева */
	}
	return undefined;
};

/**
 * Вставить host перед «Активность» или после блока обновления.
 * Возвращает true, если реально переместили в поток страницы.
 */
const placeHost = (host: HTMLElement): boolean => {
	if (!document.body) return false;
	if (host.isConnected && host.parentElement && host.parentElement !== document.body) {
		const parentText = (host.parentElement.innerText ?? '').slice(0, 200).toLowerCase();
		if (ACTIVITY_SUB.some((s) => parentText.includes(s)) || UPDATE_SUB.some((s) => parentText.includes(s))) {
			return true;
		}
	}

	const activity = findTextBySubstrings(ACTIVITY_SUB);
	if (activity?.parentElement) {
		activity.parentElement.insertBefore(host, activity);
		log('placed before activity');
		return true;
	}
	const update = findTextBySubstrings(UPDATE_SUB);
	if (update?.parentElement) {
		update.parentElement.insertAdjacentElement('afterend', host);
		log('placed after update');
		return true;
	}
	return false;
};

export const GlobalCard = () => {
	const hostRef = useRef<HTMLDivElement | null>(null);
	const [appid, setAppid] = useState<string | null>(null);
	const [placed, setPlaced] = useState(false);
	const decidedRef = useRef(false);

	useEffect(() => {
		startRouteTracking();
		const off = onRoute((route) => {
			if (route.appid && !decidedRef.current) {
				void tryDecide(route.appid);
			}
		});
		return () => {
			off();
		};
	}, []);

	const tryDecide = async (hint?: string): Promise<void> => {
		if (decidedRef.current) return;
		try {
			const state = await api.getConsent();
			if (state?.asked) {
				log('skip: already asked consent=' + String(state?.consent ?? ''));
				decidedRef.current = true;
				return;
			}
			const id = hint || findAppId();
			if (!id) {
				log('no appid yet href=' + String(location.href).slice(0, 80));
				return;
			}
			const known = await api.appKnown(id);
			if (known?.known) {
				log('skip: app known appid=' + id);
				decidedRef.current = true;
				return;
			}
			log('show card for appid=' + id);
			decidedRef.current = true;
			setAppid(id);
		} catch (e) {
			log('decide error: ' + String(e));
		}
	};

	useEffect(() => {
		void tryDecide();

		const observer = new MutationObserver(() => {
			if (!decidedRef.current) void tryDecide();
			if (appid && hostRef.current && !placed) {
				if (placeHost(hostRef.current)) setPlaced(true);
			}
		});
		if (document.body) {
			observer.observe(document.body, { childList: true, subtree: true, characterData: true });
		}
		return () => observer.disconnect();
	}, [appid, placed]);

	useEffect(() => {
		if (!appid || !hostRef.current || placed) return;
		const host = hostRef.current;
		if (placeHost(host)) {
			setPlaced(true);
			return;
		}
		host.style.cssText =
			'position:fixed;left:50%;transform:translateX(-50%);bottom:24px;z-index:2147483646;width:min(520px,calc(100vw - 32px));';
		if (!host.isConnected) document.body.appendChild(host);
		log('fallback fixed bottom center appid=' + appid);
		setPlaced(true);
	}, [appid, placed]);

	if (!appid) return null;

	return (
		<div ref={hostRef} id={CONSENT_ID} style={{ margin: '12px 0' }}>
			<ConsentCard
				appid={appid}
				onDone={() => {
					setAppid(null);
					decidedRef.current = true;
				}}
			/>
		</div>
	);
};

/** Dock отключён. */
export const GlobalDock = () => null;
