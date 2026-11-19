import { useCallback, useEffect, useRef, useState } from 'react';

import { getReactInstance } from 'millennium';

import { api } from '../lib/rpc';
import { currentRoute, onRoute, startRouteTracking } from '../lib/route';
import { ConsentCard } from './ConsentBanner';

const CONSENT_ID = 'version-rollback-consent-card';
const ACTIVITY_SUB = ['активность', 'activity', 'aktivität', 'activite', 'activité'];
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
	const needles = subs.map((s) => s.toLowerCase());
	const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
	let node: Node | null = walker.nextNode();
	while (node) {
		const text = (node.nodeValue ?? '').trim();
		if (text.length > 0 && text.length < 100) {
			const lower = text.toLowerCase();
			if (needles.some((needle) => lower.includes(needle)) && node.parentElement) {
				return node.parentElement;
			}
		}
		node = walker.nextNode();
	}
	return null;
};

/** Дата ленты: «14 октября», «14 October» — короткий текст из числа и слова. */
const DATE_RE = /^\d{1,2}\s+\p{L}+\.?$/u;

/** Первый элемент с датой ленты, идущий в документе после заданного узла. */
const findNextDateAfter = (from: HTMLElement): HTMLElement | null => {
	if (!document.body) return null;
	const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
	walker.currentNode = from;
	let node: Node | null = walker.nextNode();
	while (node) {
		const text = (node.nodeValue ?? '').trim();
		if (text.length > 0 && text.length < 30 && DATE_RE.test(text) && node.parentElement) {
			return node.parentElement;
		}
		node = walker.nextNode();
	}
	return null;
};

const commonAncestor = (a: HTMLElement, b: HTMLElement): HTMLElement | null => {
	const seen = new Set<HTMLElement>();
	for (let n: HTMLElement | null = a; n; n = n.parentElement) seen.add(n);
	for (let n: HTMLElement | null = b; n; n = n.parentElement) {
		if (seen.has(n)) return n;
	}
	return null;
};

/** Потомок `ancestor`, в котором лежит `node`. */
const childOf = (ancestor: HTMLElement, node: HTMLElement): HTMLElement | null => {
	let n: HTMLElement | null = node;
	while (n && n.parentElement !== ancestor) n = n.parentElement;
	return n;
};

const findAppId = (): string | undefined => {
	const href = `${String(location.href ?? '')} ${String(location.hash ?? '')}`;
	const fromUrl = href.match(/(?:#|\/)(?:app|details|library\/app)\/(\d{3,})(?:\/|\?|$)/i);
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
		// React-дерево Steam может быть недоступно в текущем контексте.
	}
	return undefined;
};

const placeHost = (host: HTMLElement): boolean => {
	if (!document.body) return false;
	const activity = findTextBySubstrings(ACTIVITY_SUB);
	if (activity) {
		// Предпочтительно: после поля «Расскажите…» и перед первой датой ленты.
		const dateEl = findNextDateAfter(activity);
		if (dateEl) {
			const common = commonAncestor(activity, dateEl);
			const child = common ? childOf(common, dateEl) : null;
			if (child?.parentElement) {
				child.parentElement.insertBefore(host, child);
				log('карточка размещена после поля активности, перед датой');
				return true;
			}
		}
		if (activity.parentElement) {
			activity.parentElement.insertBefore(host, activity);
			log('карточка размещена перед блоком активности');
			return true;
		}
	}
	const update = findTextBySubstrings(UPDATE_SUB);
	if (update?.parentElement) {
		update.parentElement.insertAdjacentElement('afterend', host);
		log('карточка размещена после блока обновлений');
		return true;
	}
	return false;
};

export const GlobalCard = () => {
	const hostRef = useRef<HTMLDivElement | null>(null);
	const currentAppRef = useRef<string | null>(null);
	const processedApps = useRef(new Set<string>());
	const inFlightApps = useRef(new Set<string>());
	const generation = useRef(0);
	const [appid, setAppid] = useState<string | null>(null);
	const [placed, setPlaced] = useState(false);

	const checkApp = useCallback(async (id: string, requestGeneration: number): Promise<void> => {
		if (processedApps.current.has(id) || inFlightApps.current.has(id)) return;
		inFlightApps.current.add(id);
		try {
			const consent = await api.getConsent();
			if (requestGeneration !== generation.current || currentAppRef.current !== id) return;
			if (consent?.asked) {
				processedApps.current.add(id);
				log('вопрос уже был задан; карточка не требуется');
				return;
			}
			const known = await api.appKnown(id);
			if (requestGeneration !== generation.current || currentAppRef.current !== id) return;
			processedApps.current.add(id);
			if (known?.known) {
				log(`игра ${id} уже есть в базе; карточка не требуется`);
				return;
			}
			log(`показываю карточку согласия для AppID ${id}`);
			setPlaced(false);
			setAppid(id);
		} catch (error) {
			log(`проверка для AppID ${id} не удалась: ${String(error)}`);
		} finally {
			inFlightApps.current.delete(id);
		}
	}, []);

	const selectApp = useCallback((id?: string) => {
		const next = id && /^\d{3,}$/.test(id) ? id : null;
		if (currentAppRef.current !== next) {
			currentAppRef.current = next;
			generation.current += 1;
			setAppid(null);
			setPlaced(false);
		}
		if (next) void checkApp(next, generation.current);
	}, [checkApp]);

	useEffect(() => {
		startRouteTracking();
		const off = onRoute((route) => selectApp(route.appid));
		const onConsentChanged = () => {
			processedApps.current.clear();
			selectApp(findAppId());
		};
		window.addEventListener('vrb-consent-changed', onConsentChanged);

		const scan = () => selectApp(findAppId());
		scan();
		let observer: MutationObserver | undefined;
		if (document.body) {
			observer = new MutationObserver(scan);
			observer.observe(document.body, { childList: true, subtree: true, characterData: true });
		}
		return () => {
			off();
			observer?.disconnect();
			window.removeEventListener('vrb-consent-changed', onConsentChanged);
		};
	}, [selectApp]);

	useEffect(() => {
		if (!appid || !hostRef.current || placed) return;
		const host = hostRef.current;
		if (placeHost(host)) {
			setPlaced(true);
			return;
		}
		// Если Steam изменил разметку или язык, карточка всё равно остаётся видимой.
		host.style.cssText =
			'position:fixed;left:50%;transform:translateX(-50%);bottom:24px;z-index:2147483646;width:min(520px,calc(100vw - 32px));';
		document.body?.appendChild(host);
		log(`якорь страницы не найден; карточка показана поверх окна (AppID ${appid})`);
		setPlaced(true);
	}, [appid, placed]);

	if (!appid) return null;
	return (
		<div ref={hostRef} id={CONSENT_ID} style={{ margin: '12px 0' }}>
			<ConsentCard
				appid={appid}
				onDone={() => {
					processedApps.current.add(appid);
					setAppid(null);
				}}
			/>
		</div>
	);
};

/** Dock отключён. */
export const GlobalDock = (): null => null;
