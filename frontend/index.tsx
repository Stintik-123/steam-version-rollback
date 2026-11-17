/**
 * Version Rollback — точка входа фронтенда.
 *
 * Изменения относительно 0.6.0:
 *  - GlobalDock (кнопка справа снизу) отключён.
 *  - Карточка согласия остаётся глобальной и встаёт в поток страницы игры
 *    между блоком обновления и «Активность» (как штатные баннеры Steam).
 */

import { definePlugin, routerHook } from 'millennium';

import { startUi, stopUi } from './inject';
import { api } from './lib/rpc';
import { GlobalCard } from './ui/GlobalCard';
import { SettingsPanel } from './ui/SettingsPanel';

type SteamConsole = {
	Console?: { ExecCommand?: (command: string) => void; ExecuteCommand?: (command: string) => void };
	System?: { ExecCommand?: (command: string) => void };
};

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

try {
	// Только карточка согласия. Dock больше не регистрируем.
	routerHook.addGlobalComponent('version-rollback-consent-card', GlobalCard);
	console.info('[Version Rollback] глобальные компоненты зарегистрированы (без dock)');
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

window.setTimeout(() => {
	api
		.ping()
		.then((result) => {
			console.info('[Version Rollback] backend ok ' + JSON.stringify(result));
		})
		.catch((error) => {
			console.error('[Version Rollback] backend недоступен: ' + String(error));
		});
}, 8000);

window.addEventListener('beforeunload', () => {
	try {
		stopUi();
	} catch {
		/* ignore */
	}
});
