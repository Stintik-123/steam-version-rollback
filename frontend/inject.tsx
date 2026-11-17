/**
 * Вставка UI Version Rollback в интерфейс Steam БЕЗ поллинга.
 *
 * 0.6.2: карточку согласия больше НЕ показывает inject — только GlobalCard
 * (routerHook global component). Здесь остаётся:
 *  - секция VersionPanel в «Версии и бета-версии»;
 *  - очистка старого dock;
 *  - подсказка маршрута / AppID для GlobalCard через route.ts.
 */

import { getReactInstance } from 'millennium';

import { api } from './lib/rpc';
import { onRoute, rescanFromDom, startRouteTracking } from './lib/route';
import { VersionPanel } from './ui/VersionPanel';

const removeDock = (): void => {
	document.getElementById('version-rollback-dock')?.remove();
	document.getElementById('version-rollback-dock-panel')?.remove();
};

const MARKERS = [
	'Скрытые версии',
	'Скрытые версии игры',
	'Private Versions',
	'Versions privées',
	'Private Versionen',
	'Versteckte Versionen',
	'Verisiones privadas',
	'Versiones privadas',
	'Versioni private',
	'Wersje prywatne',
	'Приватные версии',
];

const HOST_ID = 'version-rollback-betas-host';
const SETTINGS_ROOT_ID = 'version-rollback-settings-root';
const DEBOUNCE_MS = 400;
const MAX_STRIKES = 5;

type ReactDom = {
	createRoot?: (el: Element) => { render: (node: unknown) => void; unmount: () => void } | null;
	render?: (node: unknown, el: Element) => void;
	unmountComponentAtNode?: (el: Element) => void;
};

const reactDom = (): ReactDom | undefined => (globalThis as unknown as { SP_REACTDOM?: ReactDom }).SP_REACTDOM;

const log = (message: string, extra?: unknown) => console.info(`[Version Rollback] ${message}`, extra ?? '');

const note = (message: string) => {
	api.debugNote(message).catch((): void => undefined);
};

const findMarker = (): HTMLElement | null => {
	if (!document.body) return null;
	const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
	let node: Node | null = walker.nextNode();
	while (node) {
		const text = (node.nodeValue ?? '').trim();
		if (text && text.length < 40 && MARKERS.includes(text)) {
			const parent = node.parentElement;
			if (parent && parent.children.length === 0) return parent;
		}
		node = walker.nextNode();
	}
	return null;
};

const findAppId = (from: HTMLElement): string | undefined => {
	try {
		let fiber = getReactInstance(from) as any;
		for (let depth = 0; fiber && depth < 30; depth++) {
			const props = fiber.memoizedProps ?? {};
			for (const key of ['appid', 'appId', 'unAppID', 'nAppID', 'app_id']) {
				const value = props[key];
				if (typeof value === 'number' && Number.isFinite(value) && value > 0) return String(value);
				if (typeof value === 'string' && /^\d{2,}$/.test(value)) return value;
			}
			fiber = fiber.return;
		}
	} catch (error) {
		log('не удалось прочитать AppID из React-дерева', String(error));
	}
	return undefined;
};

const findLibraryAppId = (): string | undefined => {
	try {
		const href = String(location.href ?? '') + String(location.hash ?? '');
		const m = href.match(/(?:#|\/)(?:app|details|library\/app)\/(\d{3,})/i) ?? href.match(/\/app\/(\d{3,})/);
		if (m) return m[1];
		const anchor =
			document.querySelector<HTMLElement>('[class*="appdetailsoverview"]') ??
			document.querySelector<HTMLElement>('[class*="libraryappdetails"]') ??
			document.querySelector<HTMLElement>('[class*="AppDetails"]') ??
			document.querySelector<HTMLElement>('[class*="appdetailsgamepad"]');
		if (!anchor) return undefined;
		return findAppId(anchor);
	} catch {
		return undefined;
	}
};

const findPageContainer = (marker: HTMLElement): HTMLElement | null => {
	let node: HTMLElement | null = marker.parentElement;
	for (let depth = 0; node && depth < 6; depth++) {
		if (node.querySelector('input')) return node;
		node = node.parentElement;
	}
	return marker.parentElement;
};

let betasRoot: { unmount: () => void } | null = null;
let betasHost: HTMLElement | null = null;
let observer: MutationObserver | null = null;
let debounceTimer: number | null = null;
let strikes = 0;
let stopped = false;

const unmountBetas = (): void => {
	try {
		betasRoot?.unmount();
	} catch (error) {
		log('ошибка при снятии секции', String(error));
	}
	betasRoot = null;
	betasHost?.remove();
	betasHost = null;
};

const mountBetas = (marker: HTMLElement): void => {
	const dom = reactDom();
	if (!dom?.createRoot && !dom?.render) {
		note('no reactdom: ' + typeof dom);
		return;
	}
	const container = findPageContainer(marker);
	if (!container) return;

	betasHost = document.createElement('div');
	betasHost.id = HOST_ID;
	betasHost.style.margin = '12px 0 4px';
	betasHost.textContent = 'Version Rollback: загрузка панели…';
	container.appendChild(betasHost);

	const appid = findAppId(marker);
	const element = <VersionPanel appidHint={appid} context="library" />;
	try {
		if (dom.createRoot) {
			const root = dom.createRoot(betasHost);
			if (!root) throw new Error('createRoot вернул null');
			root.render(element);
			betasRoot = root;
		} else {
			dom.render?.(element, betasHost);
			betasRoot = { unmount: () => dom.unmountComponentAtNode?.(betasHost as HTMLElement) };
		}
		log('секция вставлена в «Версии и бета-версии»', { appid: appid ?? '(не определён)' });
	} catch (error) {
		log('не удалось смонтировать секцию', String(error));
		if (betasHost) betasHost.textContent = 'Version Rollback: не удалось показать панель — ' + String(error);
		betasRoot = null;
	}
};

const refresh = (): void => {
	if (stopped) return;
	try {
		if (!document.body) return;

		if (document.getElementById(SETTINGS_ROOT_ID)) {
			removeDock();
			unmountBetas();
			return;
		}

		removeDock();

		const marker = findMarker();
		if (marker) {
			if (!betasHost || !document.contains(betasHost)) {
				unmountBetas();
				mountBetas(marker);
			}
		} else if (betasHost) {
			unmountBetas();
		}

		const domAppId = marker ? findAppId(marker) : findLibraryAppId();
		rescanFromDom(domAppId, Boolean(marker));

		strikes = 0;
	} catch (error) {
		strikes += 1;
		console.error('[Version Rollback] ошибка инъекции:', error);
		if (strikes >= MAX_STRIKES) {
			stopped = true;
			observer?.disconnect();
			observer = null;
			note('injection disabled after ' + String(MAX_STRIKES) + ' strikes: ' + String(error).slice(0, 200));
		}
	}
};

const scheduleRefresh = (): void => {
	if (stopped) return;
	if (debounceTimer !== null) window.clearTimeout(debounceTimer);
	debounceTimer = window.setTimeout(() => {
		debounceTimer = null;
		refresh();
	}, DEBOUNCE_MS);
};

export const startUi = (): void => {
	if (observer || stopped) return;
	startRouteTracking();
	onRoute(() => {
		scheduleRefresh();
	});

	if (typeof MutationObserver !== 'undefined' && document.body) {
		observer = new MutationObserver(scheduleRefresh);
		observer.observe(document.body, { childList: true, subtree: true });
	}

	window.setTimeout(scheduleRefresh, 1500);
	window.setTimeout(scheduleRefresh, 6000);
	note('inject start 0.6.2 (consent only via GlobalCard)');
};

export const stopUi = (): void => {
	stopped = true;
	observer?.disconnect();
	observer = null;
	if (debounceTimer !== null) window.clearTimeout(debounceTimer);
	debounceTimer = null;
	unmountBetas();
	removeDock();
};

export const invalidateConsentCache = (): void => {
	window.dispatchEvent(new Event('vrb-consent-changed'));
};
