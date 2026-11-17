/**
 * Вставка UI Version Rollback в интерфейс Steam БЕЗ поллинга.
 *
 * Что здесь изменилось по сравнению с 0.5.x (причина краха 0xC0000409):
 *  - убраны ВСЕ setInterval: раньше каждые 800 мс сканировался весь документ
 *    (querySelectorAll по div/span/h2/h3 + getBoundingClientRect у каждого
 *    листа), а каждые 1.5 с пересоздавалась кнопка — постоянная грелка layout
 *    в CEF и гонка с перерисовками Steam;
 *  - вместо этого один MutationObserver с дебаунсом 400 мс: реагируем только
 *    на реальные изменения DOM, маркер ищем TreeWalker-ом по текстовым узлам
 *    без принудительного layout;
 *  - RPC-вызовы при монтировании сведены к минимуму и идут через
 *    последовательную очередь (lib/rpc.ts) — одновременных callServerMethod
 *    больше не бывает;
 *  - любое монтирование обёрнуто в try/catch, а после нескольких подряд
 *    ошибок инъекция сама отключается на сессию и пишет диагностику, вместо
 *    того чтобы молотить по хосту.
 */

import { getReactInstance } from 'millennium';

import { api } from './lib/rpc';
import { onRoute, rescanFromDom, startRouteTracking } from './lib/route';
import { ConsentCard } from './ui/ConsentBanner';
import { ensureDock, removeDock } from './ui/dock';
import { VersionPanel } from './ui/VersionPanel';

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

/** Заголовок секции «Активность» — карточку ставим прямо над ним. */
const ACTIVITY_MARKERS = ['Активность', 'Activity', 'Aktivität', 'Activité'];
/** Блок «Небольшое обновление или список изменений» — запасной якорь. */
const UPDATE_MARKERS = [
	'Небольшое обновление или список изменений',
	'Небольшое обновление',
	'Minor update or change list',
	'Minor update',
];

const HOST_ID = 'version-rollback-betas-host';
const CONSENT_ID = 'version-rollback-consent-card';
const SETTINGS_ROOT_ID = 'version-rollback-settings-root';
const DEBOUNCE_MS = 400;
/** Сколько подряд ошибок инъекции терпим, прежде чем отключиться на сессию. */
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

/* ------------------------------------------------------------------ */
/* Поиск маркера страницы «Версии и бета-версии» без layout-треша.     */
/* ------------------------------------------------------------------ */

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

/** AppID из React-пропсов ближайших родителей: у страницы свойств он рядом. */
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

/** Запасной способ узнать appid страницы игры: React-пропсы её контейнера. */
const findLibraryAppId = (): string | undefined => {
	try {
		const anchor =
			document.querySelector<HTMLElement>('[class*="appdetailsoverview"]') ??
			document.querySelector<HTMLElement>('[class*="libraryappdetails"]') ??
			document.querySelector<HTMLElement>('[class*="appdetailsgamepad"]');
		if (!anchor) return undefined;
		return findAppId(anchor);
	} catch {
		return undefined;
	}
};

/** Контейнер страницы: поднимаемся от заголовка, пока не найдём блок с полем ввода кода. */
const findPageContainer = (marker: HTMLElement): HTMLElement | null => {
	let node: HTMLElement | null = marker.parentElement;
	for (let depth = 0; node && depth < 6; depth++) {
		if (node.querySelector('input')) return node;
		node = node.parentElement;
	}
	return marker.parentElement;
};

/* ------------------------------------------------------------------ */
/* Состояние инъекции.                                                 */
/* ------------------------------------------------------------------ */

let betasRoot: { unmount: () => void } | null = null;
let betasHost: HTMLElement | null = null;
let consentRoot: { unmount: () => void } | null = null;
let observer: MutationObserver | null = null;
let debounceTimer: number | null = null;
let strikes = 0;
let stopped = false;

let consentCache: { consent: string; asked: boolean } | null = null;
const knownCache = new Map<string, boolean>();
let consentAppId: string | undefined;

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

const unmountConsent = (): void => {
	try {
		consentRoot?.unmount();
	} catch {
		/* уже снят */
	}
	consentRoot = null;
	document.getElementById(CONSENT_ID)?.remove();
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

/* ------------------------------------------------------------------ */
/* Согласие на сбор: один вопрос за всё время.                         */
/* ------------------------------------------------------------------ */

/** Найти элемент по точному тексту (TreeWalker, без layout-треша). */
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

/**
 * Согласие на сбор: один вопрос за всё время.
 *
 * Карточка вставляется в страницу библиотеки — между блоком «Небольшое
 * обновление или список изменений» и секцией «Активность». Если нужных
 * заголовков нет (другая вёрстка/язык) — остаётся плавающий вариант
 * в правом нижнем углу.
 */
const showConsentCard = (appid: string): void => {
	if (document.getElementById(CONSENT_ID)) return;
	const dom = reactDom();
	if (!dom?.createRoot) {
		// Без React вопрос можно задать в настройках плагина — не падаем.
		note('consent card skipped: no reactdom');
		return;
	}
	const host = document.createElement('div');
	host.id = CONSENT_ID;

	const activity = findTextElement(ACTIVITY_MARKERS);
	const update = findTextElement(UPDATE_MARKERS);
	if (activity) {
		// Идёт в поток страницы: между «Небольшое обновление» и «Активность».
		host.style.cssText = 'margin:12px 0;';
		activity.parentElement?.insertBefore(host, activity);
	} else {
		host.style.cssText = 'position:fixed;right:24px;bottom:84px;z-index:2147483647;width:360px;';
		document.body.appendChild(host);
	}
	try {
		const root = dom.createRoot(host);
		if (!root) throw new Error('createRoot вернул null');
		root.render(
			<ConsentCard
				appid={appid}
				onDone={() => {
					consentCache = null;
					window.setTimeout(() => unmountConsent(), 12000);
				}}
			/>,
		);
		consentRoot = root;
		note('consent card shown for ' + appid + ' (anchor: ' + (activity ? 'activity' : update ? 'update' : 'floating') + ')');
	} catch (error) {
		log('не удалось показать карточку согласия', String(error));
		host.remove();
	}
};

/**
 * Точка входа вопроса: игра, которой нет в общей базе версий.
 * Спрашиваем ровно один раз: ответ хранится в настройках Millennium
 * (collect_consent + consent_shown_for=scope-1).
 */
const maybeAskConsent = (appid: string | undefined): void => {
	if (!appid || consentAppId === appid || document.getElementById(CONSENT_ID)) return;
	consentAppId = appid;

	void (async () => {
		try {
			if (!consentCache) {
				const state = await api.getConsent();
				consentCache = { consent: String(state?.consent ?? ''), asked: Boolean(state?.asked) };
			}
			if (consentCache.asked) return; // уже отвечали — не переспрашиваем
			if (knownCache.has(appid)) return;
			const known = await api.appKnown(appid);
			knownCache.set(appid, Boolean(known?.known));
			if (known?.known) return; // игра уже в базе — собирать нечего
			showConsentCard(appid);
		} catch (error) {
			// Бэкенд недоступен — не показываем карточку, попробуем на другой игре.
			consentAppId = undefined;
			log('проверка согласия отложена', String(error));
		}
	})();
};

window.addEventListener('vrb-consent-changed', () => {
	consentCache = null;
	consentAppId = undefined;
});

/* ------------------------------------------------------------------ */
/* Главный цикл реакции на DOM.                                        */
/* ------------------------------------------------------------------ */

const refresh = (): void => {
	if (stopped) return;
	try {
		if (!document.body) return;

		// Открыты настройки плагина — там свой UI, инъекции не нужны.
		if (document.getElementById(SETTINGS_ROOT_ID)) {
			removeDock();
			unmountBetas();
			unmountConsent();
			return;
		}

		ensureDock();

		// Секция «Версии и бета-версии» в свойствах игры.
		const marker = findMarker();
		if (marker) {
			if (!betasHost || !document.contains(betasHost)) {
				unmountBetas();
				mountBetas(marker);
			}
		} else if (betasHost) {
			unmountBetas();
		}

		// Согласие: appid берём из навигации, затем из DOM-сигналов.
		const domAppId = marker ? findAppId(marker) : findLibraryAppId();
		rescanFromDom(domAppId, Boolean(marker));
		maybeAskConsent(domAppId ?? undefined);

		strikes = 0;
	} catch (error) {
		strikes += 1;
		console.error('[Version Rollback] ошибка инъекции:', error);
		if (strikes >= MAX_STRIKES) {
			stopped = true;
			observer?.disconnect();
			observer = null;
			unmountConsent();
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

/** Единственная точка входа инъекций. Вызывается из index.tsx один раз. */
export const startUi = (): void => {
	if (observer || stopped) return;
	startRouteTracking();
	onRoute((route) => {
		if (route.appid) maybeAskConsent(route.appid);
		scheduleRefresh();
	});

	if (typeof MutationObserver !== 'undefined' && document.body) {
		observer = new MutationObserver(scheduleRefresh);
		observer.observe(document.body, { childList: true, subtree: true });
	}

	// Первая отрисовка Steam может запаздывать: две разовые попытки, не интервал.
	window.setTimeout(scheduleRefresh, 1500);
	window.setTimeout(scheduleRefresh, 6000);
	note('inject start (observer mode)');
};

/** Полная остановка: выгрузка плагина / перезапуск UI. */
export const stopUi = (): void => {
	stopped = true;
	observer?.disconnect();
	observer = null;
	if (debounceTimer !== null) window.clearTimeout(debounceTimer);
	debounceTimer = null;
	unmountBetas();
	unmountConsent();
	removeDock();
};

/** Для настроек плагина: сбросить кэш согласия, чтобы карточка перечиталась. */
export const invalidateConsentCache = (): void => {
	consentCache = null;
	consentAppId = undefined;
	window.dispatchEvent(new Event('vrb-consent-changed'));
};
