import { useEffect, useRef, useState } from 'react';

import { getReactInstance } from 'millennium';

import { api } from '../lib/rpc';
import { ConsentCard } from './ConsentBanner';

/**
 * Видимый слой плагина в настоящем окне Steam.
 *
 * - Карточка согласия: между «Небольшое обновление» и «Активность»
 *   (как штатный баннер framerate / revise review).
 * - Кнопку в правом нижнем углу УБРАЛИ — доступ только через
 *   свойства игры («Версии и бета-версии») и настройки Millennium.
 */

const ACTIVITY_MARKERS = ['Активность', 'Activity', 'Aktivität', 'Activité'];
const UPDATE_MARKERS = [
	'Небольшое обновление или список изменений',
	'Небольшое обновление',
	'Minor update or change list',
	'Minor update',
	'SMALL UPDATE / PATCH NOTES',
	'FEATURED',
];

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
		/* без React-дерева */
	}
	return undefined;
};

export const GlobalCard = () => {
	const cardRef = useRef<HTMLDivElement | null>(null);
	const [appid, setAppid] = useState<string | null>(null);
	const [placed, setPlaced] = useState(false);

	useEffect(() => {
		let cancelled = false;

		const decide = async (): Promise<void> => {
			try {
				const state = await api.getConsent();
				if (cancelled || state?.asked) return;
				const id = findAppId();
				if (!id) return;
				const known = await api.appKnown(id);
				if (cancelled || known?.known) return;
				setAppid(id);
			} catch {
				/* бэкенд недоступен */
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

	// Вставка между Featured/Update и Activity — как у штатных баннеров Steam
	useEffect(() => {
		if (!appid || !cardRef.current || placed) return;
		const node = cardRef.current;
		let tries = 0;
		const tryPlace = (): void => {
			const activity = findTextElement(ACTIVITY_MARKERS);
			if (activity?.parentElement) {
				activity.parentElement.insertBefore(node, activity);
				setPlaced(true);
				api.debugNote('card placed before activity, appid=' + appid).catch((): void => undefined);
				return;
			}
			// запасной якорь — после блока обновления
			const update = findTextElement(UPDATE_MARKERS);
			if (update?.parentElement) {
				update.parentElement.insertAdjacentElement('afterend', node);
				setPlaced(true);
				api.debugNote('card placed after update, appid=' + appid).catch((): void => undefined);
				return;
			}
			tries += 1;
			if (tries < 40) {
				window.setTimeout(tryPlace, 400);
				return;
			}
			// совсем нет якорей — оставляем в потоке (не floating)
			api.debugNote('anchor not found, appid=' + appid).catch((): void => undefined);
			setPlaced(true);
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

/**
 * GlobalDock отключён: кнопку в правом нижнем углу убрали по запросу.
 * Доступ к панели — через свойства игры и настройки Millennium.
 */
export const GlobalDock = () => null;
