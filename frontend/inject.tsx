/**
 * Вставка секции Version Rollback в штатную страницу свойств игры
 * «Версии и бета-версии» (Свойства → Версии и бета-версии).
 *
 * Почему DOM-инъекция, а не патч JS: патчи Millennium — это регулярки по
 * минифицированному коду конкретной сборки клиента, они ломаются от любого
 * обновления Steam. Здесь мы ищем уже отрисованную страницу по тексту заголовка
 * «Скрытые версии» и монтируем свой React-корень в её контейнер.
 *
 * Что важно:
 *  - маркеры локализованы, поэтому список языков, а не одна строка;
 *  - контейнер принадлежит React, он может выкинуть наш узел при перерисовке —
 *    поэтому раз в 800 мс проверяем, на месте ли он, и монтируем заново;
 *  - ReactDOM берём у Steam (SP_REACTDOM), чтобы не тащить второй React.
 */

import { getReactInstance } from 'millennium';

import { api } from './lib/rpc';
import { LibraryDock } from './ui/LibraryDock';
import { VersionPanel } from './ui/VersionPanel';

const MARKERS = [
	'Скрытые версии',
	'Скрытые версии игры',
	'Private Versions',
	'Versions privées',
	'Private Versionen',
	'Versteckte Versionen',
	'Versiones privadas',
	'Versioni private',
	'Wersje prywatne',
	'Приватные версии',
];

const HOST_ID = 'version-rollback-betas-host';
const POLL_MS = 800;

/**
 * Идентификаторы своих узлов, чтобы не монтировать одно и то же дважды.
 */
const BANNER_ID = 'version-rollback-library-dock';
const SETTINGS_ROOT_ID = 'version-rollback-settings-root';

const log = (message: string, extra?: unknown) =>
	console.info(`[Version Rollback] ${message}`, extra ?? '');

/** Диагностика в файл: консоль Steam UI не всегда доступна, а файл — да. */
const note = (message: string) => {
	api.debugNote(message).catch((): void => undefined);
};

const isVisible = (el: HTMLElement): boolean => {
	const rect = el.getBoundingClientRect();
	return rect.width > 0 && rect.height > 0;
};

/** Заголовок «Скрытые версии» — единственный надёжный текстовый якорь на странице. */
const findMarker = (): HTMLElement | null => {
	const nodes = document.querySelectorAll<HTMLElement>('div, span, h2, h3');
	for (const el of Array.from(nodes)) {
		if (el.children.length > 0) continue;
		const text = el.textContent?.trim();
		if (text && MARKERS.includes(text) && isVisible(el)) return el;
	}
	return null;
};

/** AppID из React-пропсов ближайших родителей: у страницы свойств он где-то рядом. */
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

/** Контейнер страницы: поднимаемся от заголовка, пока не найдём блок с полем ввода кода. */
const findPageContainer = (marker: HTMLElement): HTMLElement | null => {
	let node: HTMLElement | null = marker.parentElement;
	for (let depth = 0; node && depth < 6; depth++) {
		if (node.querySelector('input')) return node;
		node = node.parentElement;
	}
	return marker.parentElement;
};

export const startBetasSection = (): void => {
	const reactDom = (globalThis as unknown as { SP_REACTDOM?: any }).SP_REACTDOM;
	if (!reactDom || (!reactDom.createRoot && !reactDom.render)) {
		log('SP_REACTDOM недоступен — секция в свойствах не будет вставлена', typeof reactDom);
		note('no reactdom: ' + typeof reactDom);
		return;
	}
	let root: { unmount: () => void } | null = null;
	let host: HTMLElement | null = null;
	let reportedNoMarker = false;

	note('inject start, reactDom=' + typeof reactDom);

	const unmount = () => {
		try {
			root?.unmount();
		} catch (error) {
			log('ошибка при снятии секции', String(error));
		}
		root = null;
		host = null;
	};

	const tick = () => {
		const marker = findMarker();

		if (!marker) {
			if (host && !document.contains(host)) unmount();
			if (!reportedNoMarker) {
				reportedNoMarker = true;
				const hasText = (document.body?.innerText ?? '').includes('Скрытые версии');
				note('no marker; text present=' + hasText);
			}
			return;
		}

		if (host && document.contains(host)) return; // уже стоит на месте
		if (host) unmount(); // React выкинул наш узел — монтируем заново

		const container = findPageContainer(marker);
		if (!container) {
			log('не нашёл контейнер страницы версий');
			return;
		}

		host = document.createElement('div');
		host.id = HOST_ID;
		host.style.margin = '12px 0 4px';
		// Текст до рендера: если React упадёт, пользователь увидит хотя бы это,
		// а не пустое место.
		host.textContent = 'Version Rollback: загрузка панели…';
		container.appendChild(host);

		const appid = findAppId(marker);
		const element = <VersionPanel appidHint={appid} context="library" />;

		try {
			if (reactDom.createRoot) {
				const created = reactDom.createRoot(host);
				created.render(element);
				root = created;
			} else {
				reactDom.render(element, host);
				root = { unmount: () => reactDom.unmountComponentAtNode(host) };
			}
			reportedNoMarker = false;
			try {
				localStorage.setItem('vrb-mounted', String(appid ?? 'none') + ' ' + new Date().toISOString());
			} catch {
				/* игнорируем */
			}
			log('секция вставлена в «Версии и бета-версии»', { appid: appid ?? '(не определён)' });
			note('mounted appid=' + (appid ?? 'none'));
		} catch (error) {
			log('не удалось смонтировать секцию', String(error));
			note('mount error: ' + String(error));
			if (host) host.textContent = 'Version Rollback: не удалось показать панель — ' + String(error);
		}
	};

	setInterval(tick, POLL_MS);
	tick();
};

/**
 * Кнопка-панель Version Rollback в разделе «Библиотека».
 *
 * Монтируется поверх страницы библиотеки (правый нижний угол). В настройках
 * плагина панели нет: решение о версии принимается там, где видны игры.
 */
export const startLibraryDock = (): void => {
	const reactDom = (globalThis as unknown as { SP_REACTDOM?: any }).SP_REACTDOM;
	if (!reactDom || (!reactDom.createRoot && !reactDom.render)) {
		log('SP_REACTDOM недоступен — баннер согласия не появится', typeof reactDom);
		return;
	}

	let root: { unmount: () => void } | null = null;
	let host: HTMLElement | null = null;

	const unmount = () => {
		const element = host;
		try {
			root?.unmount();
		} catch (error) {
			log('ошибка при снятии баннера', String(error));
		}
		try {
			element?.remove();
		} catch {
			/* игнорируем */
		}
		root = null;
		host = null;
	};

	const isLibraryPage = (): boolean => {
		// настройки плагина открыты — панель там не нужна
		if (document.getElementById(SETTINGS_ROOT_ID)) return false;
		// маркеры библиотеки — подсказка, а не обязательное условие: вёрстка Steam
		// меняется от версии к версии. Если ни один не найден, всё равно показываем
		// кнопку: маленькая плашка в углу не мешает и в магазине.
		return true;
	};

	const tick = () => {
		if (!isLibraryPage()) {
			if (host) unmount();
			return;
		}
		if (host && document.contains(host)) return;
		if (host) unmount();

		host = document.createElement('div');
		host.id = BANNER_ID;
		host.style.cssText = 'position:fixed;right:24px;bottom:24px;z-index:2147483647;';
		document.body.appendChild(host);

		const element = <LibraryDock />;
		try {
			if (reactDom.createRoot) {
				const created = reactDom.createRoot(host);
				created.render(element);
				root = created;
			} else {
				reactDom.render(element, host);
				root = { unmount: () => reactDom.unmountComponentAtNode(host) };
			}
			note('library dock mounted');
			log('панель Version Rollback показана в библиотеке');
		} catch (error) {
			log('не удалось показать баннер согласия', String(error));
			note('banner error: ' + String(error));
		}
	};

	setInterval(tick, POLL_MS);
	tick();
};
