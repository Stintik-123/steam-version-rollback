/**
 * Version Rollback — точка входа фронтенда (starlight / millennium.toml).
 *
 * Правила starlight, которые важно не нарушать:
 *   - `definePlugin` возвращает { title, icon, content }, icon обязателен;
 *   - функции, вызываемые из Lua через millennium.call_frontend_method,
 *     помечаются `/** @ffi *\\/` и экспортируются именно из этого файла;
 *   - у параметров @ffi-функций должен быть явный тип.
 *
 * Правила стабильности (после краха 0xC0000409 в 0.5.x):
 *   - при загрузке бандла НЕ делается ничего, кроме регистрации плагина и
 *     отложенного старта инъекций (inject.tsx) — никаких интервалов и RPC
 *     в момент старта Steam;
 *   - все RPC идут последовательной очередью с таймаутами (lib/rpc.ts);
 *   - любая ошибка инъекции ловится локально и не может уронить ни окно
 *     Steam, ни Lua-хост.
 */

import { definePlugin, routerHook } from 'millennium';

import { startUi, stopUi } from './inject';
import { api } from './lib/rpc';
import { GlobalCard, GlobalDock } from './ui/GlobalCard';
import { SettingsPanel } from './ui/SettingsPanel';

type SteamConsole = {
	Console?: { ExecCommand?: (command: string) => void; ExecuteCommand?: (command: string) => void };
	System?: { ExecCommand?: (command: string) => void };
};

/**
 * Единственный путь выполнить консольную команду Steam (`download_depot`).
 * Из Lua это невозможно — команда живёт в JS-контексте клиента.
 * Возвращаем boolean, чтобы бэкенд отличил «команда отправлена» от «API нет».
 */
/** @ffi */
export function execConsole(command: string): boolean {
	const sc = (globalThis as unknown as { SteamClient?: SteamConsole }).SteamClient;
	const consoleApi = sc?.Console;
	const fn = consoleApi?.ExecCommand ?? sc?.System?.ExecCommand ?? consoleApi?.ExecuteCommand;
	if (!fn) {
		console.error('[Version Rollback] нет SteamClient.Console.ExecCommand:', command);
		return false;
	}
	try {
		fn.call(consoleApi ?? sc?.System, String(command));
		console.info('[Version Rollback] консоль:', command);
		return true;
	} catch (error) {
		console.error('[Version Rollback] ExecCommand упал:', error);
		return false;
	}
}

const Icon = () => (
	<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
		<path d="M8 1a7 7 0 1 0 3.36 13.14l-1.02-1.72A5 5 0 1 1 13 8h2A7 7 0 0 0 8 1Z" />
		<path d="M7.2 4.6h1.6v3.9l2.6 1.5-.8 1.4-3.4-2V4.6Z" />
	</svg>
);

/**
 * Видимый слой рендерим глобальным компонентом Millennium: бандл плагина
 * грузится в SharedJSContext (служебное невидимое окно), и вставленный туда
 * DOM пользователю не виден. Глобальный компонент монтируется в настоящем
 * окне Steam — там карточка и встаёт между «Небольшое обновление» и «Активность».
 */
try {
	routerHook.addGlobalComponent('version-rollback-consent-card', GlobalCard);
	routerHook.addGlobalComponent('version-rollback-dock', GlobalDock);
	console.info('[Version Rollback] глобальные компоненты зарегистрированы');
} catch (error) {
	console.error('[Version Rollback] routerHook недоступен:', error);
}

export default definePlugin(() => ({
	title: 'Version Rollback',
	icon: <Icon />,
	content: (
		<div id="version-rollback-settings-root" style={{ padding: '8px 0' }}>
			<SettingsPanel />
		</div>
	),
}));

/* Старт инъекций — отложенный и одноразовый: Steam в момент загрузки бандла
 * ещё дорисовывает окно, а нам незачем быть первыми. */
let started = false;
const startOnce = (): void => {
	if (started) return;
	started = true;
	try {
		startUi();
	} catch (error) {
		console.error('[Version Rollback] не удалось запустить вставку UI:', error);
	}
};

if (typeof requestIdleCallback === 'function') {
	requestIdleCallback(() => startOnce(), { timeout: 5000 });
} else {
	window.setTimeout(startOnce, 2500);
}

/* Разовая самопроверка связи с бэкендом — для диагностики, без интервалов. */
window.setTimeout(() => {
	api
		.ping()
		.then((result) => {
			console.info('[Version Rollback] backend ok ' + JSON.stringify(result));
			try {
				localStorage.setItem('vrb-probe', 'ok ' + JSON.stringify(result));
			} catch {
				/* игнорируем */
			}
		})
		.catch((error) => {
			console.error('[Version Rollback] backend недоступен: ' + String(error));
			try {
				localStorage.setItem('vrb-probe', 'fail ' + String(error));
			} catch {
				/* игнорируем */
			}
		});
}, 8000);

/* Диагностика контекста: в каком окне живёт фронтенд и что видно в DOM. */
window.setTimeout(() => {
	const info = {
		title: document.title,
		href: String(location.href).slice(0, 120),
		ready: document.readyState,
		bodyText: (document.body?.innerText ?? '').slice(0, 120).replace(/\s+/g, ' '),
		hasActivity: (document.body?.innerText ?? '').includes('Активность'),
		hasUpdate: (document.body?.innerText ?? '').includes('Небольшое обновление'),
		iframes: document.querySelectorAll('iframe').length,
		w: window.innerWidth,
	};
	api.debugNote('ctx ' + JSON.stringify(info)).catch((): void => undefined);
}, 5000);

/* Чистый выход: снять корни и observer при перезапуске UI/выгрузке плагина. */
window.addEventListener('beforeunload', () => {
	try {
		stopUi();
	} catch {
		/* игнорируем */
	}
});
