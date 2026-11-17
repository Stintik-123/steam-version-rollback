/**
 * Понимание, где сейчас пользователь внутри Steam, без поллинга.
 *
 * Источники навигации: SteamClient.URL.RegisterNavigateHandler, popstate/
 * hashchange и DOM-rescan из inject.tsx.
 */

export type RouteInfo = {
	raw: string;
	appid?: string;
	isProperties: boolean;
	isLibraryApp: boolean;
};

const listeners = new Set<(route: RouteInfo) => void>();
let current: RouteInfo = { raw: '', isProperties: false, isLibraryApp: false };

const parse = (raw: string): RouteInfo => {
	const text = String(raw ?? '');
	// Поддерживаем как library/app/<id>, так и app/<id> и старые app/app/<id> маршруты.
	const match =
		text.match(/(?:^|[\/#])(?:library\/)?app\/(\d+)(?:[\/?#]|$)/i) ??
		text.match(/(?:^|[\/#])details\/(\d+)(?:[\/?#]|$)/i) ??
		text.match(/(?:^|\/)app\/app\/(\d+)(?:[\/?#]|$)/i);
	const isProperties = /properties/i.test(text);
	const isLibraryApp = Boolean(match) && !isProperties && !/store\.steampowered\.com/i.test(text);
	return {
		raw: text,
		appid: match?.[1],
		isProperties,
		isLibraryApp,
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
	try {
		emit(parse(window.location.href));
	} catch {
		// Контекст без location: дождёмся сигнала Steam или DOM-rescan.
	}
};

export const rescanFromDom = (domAppId: string | undefined, propertiesPage: boolean): void => {
	const next: RouteInfo = {
		raw: current.raw,
		appid: domAppId ?? current.appid,
		isProperties: propertiesPage || current.isProperties,
		isLibraryApp: Boolean(domAppId) && !propertiesPage,
	};
	if (next.appid !== current.appid || next.isProperties !== current.isProperties || next.isLibraryApp !== current.isLibraryApp) {
		emit(next);
	}
};

export const currentRoute = (): RouteInfo => current;

export const onRoute = (listener: (route: RouteInfo) => void): (() => void) => {
	listeners.add(listener);
	return () => listeners.delete(listener);
};
