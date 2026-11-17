/**
 * Понимание, где сейчас пользователь внутри Steam, без поллинга.
 *
 * Раньше контекст страницы определяли интервалом, который каждые 800 мс
 * сканировал ВЕСЬ документ (querySelectorAll + getBoundingClientRect) — это
* грело layout движка CEF на каждом кадре перерисовки и было одним из
 * подозреваемых в падении хоста. Теперь сигналов три, и все событийные:
 *   1) SteamClient.URL.RegisterNavigateHandler — штатный крючок навигации;
 *   2) popstate/hashchange на случай, если клиента ведёт себя как SPA;
 *   3) MutationObserver из inject.tsx вызывает rescan() при изменении DOM —
 *      тогда appid дочитывается из React-пропсов уже найденного контейнера.
 */

export type RouteInfo = {
	/** Сырая строка навигации, например `library/app/292030`. */
	raw: string;
	/** AppID из URL, если он там есть. */
	appid?: string;
	/** Это страница свойств игры (там живёт раздел «Версии и бета-версии»). */
	isProperties: boolean;
	/** Это страница игры в библиотеке (как на скриншоте с «Установить»). */
	isLibraryApp: boolean;
};

const listeners = new Set<(route: RouteInfo) => void>();

let current: RouteInfo = { raw: '', isProperties: false, isLibraryApp: false };

const parse = (raw: string): RouteInfo => {
	const text = String(raw ?? '');
	const match = text.match(/(?:library|app)\/app\/(\d+)/) ?? text.match(/\/app\/(\d+)/);
	return {
		raw: text,
		appid: match ? match[1] : undefined,
		isProperties: /properties/i.test(text),
		isLibraryApp: Boolean(match) && !/properties|store\./i.test(text),
	};
};

const emit = (route: RouteInfo): void => {
	current = route;
	for (const listener of Array.from(listeners)) {
		try {
			listener(route);
		} catch (error) {
			console.error('[Version Rollback] обработчик маршрута упал:', error);
		}
	}
};

let started = false;

/** Подписать источник навигации. Вызывается один раз из inject.tsx. */
export const startRouteTracking = (): void => {
	if (started) return;
	started = true;

	const sc = (globalThis as any).SteamClient;
	try {
		const register = sc?.URL?.RegisterNavigateHandler;
		if (typeof register === 'function') {
			register.call(sc.URL, (url: string) => emit(parse(url)));
		}
	} catch (error) {
		console.error('[Version Rollback] RegisterNavigateHandler недоступен:', error);
	}

	window.addEventListener('popstate', () => emit(parse(window.location.href)));
	window.addEventListener('hashchange', () => emit(parse(window.location.href)));

	// Первая оценка — по текущему URL окна библиотеки.
	try {
		emit(parse(window.location.href));
	} catch {
		/* окружение без location (SharedJSContext) — останемся на событийных сигналах */
	}
};

/** inject.tsx зовёт это после debounceMutation, когда DOM изменился. */
export const rescanFromDom = (domAppId: string | undefined, propertiesPage: boolean): void => {
	const next: RouteInfo = {
		raw: current.raw,
		appid: domAppId ?? current.appid,
		isProperties: propertiesPage || current.isProperties,
		isLibraryApp: Boolean(domAppId) && !propertiesPage,
	};
	if (next.appid !== current.appid || next.isProperties !== current.isProperties) emit(next);
};

export const currentRoute = (): RouteInfo => current;

export const onRoute = (listener: (route: RouteInfo) => void): (() => void) => {
	listeners.add(listener);
	return () => listeners.delete(listener);
};
