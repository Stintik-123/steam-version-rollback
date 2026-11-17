/**
 * Version Rollback — точка входа фронтенда (starlight/millennium.toml).
 *
 * Здесь регистрация плагина, FFI-функция для Lua-бэкенда и запуск вставки
 * секции в штатную страницу «Версии и бета-версии» (см. ./inject.tsx).
 *
 * Правила starlight, которые важно не нарушать:
 *   - `definePlugin` возвращает { title, icon, content }, icon обязателен;
 *   - функции, вызываемые из Lua через millennium.call_frontend_method,
 *     помечаются `/** @ffi *\/` и экспортируются именно из этого файла;
 *   - у параметров @ffi-функций должен быть явный тип.
 */

import { definePlugin } from 'millennium';

import { startBetasSection } from './inject';
import { api } from './lib/rpc';
import { mountDock } from './ui/dock';

/** Диагностика: одна метка на запуск, чтобы было видно, что бандл исполнился. */
try {
	localStorage.setItem('vrb-diag', 'boot ' + new Date().toISOString());
	const w = globalThis as unknown as Record<string, unknown>;
	const keys = Object.keys(w).filter((key) => /backend|ffi|millennium/i.test(key));
	localStorage.setItem(
		'vrb-env',
		JSON.stringify({
			backend: typeof w.backend,
			ffi: typeof w.MILLENNIUM_PRIVATE_INTERNAL_FOREIGN_FUNCTION_INTERFACE_DO_NOT_USE,
			keys,
		}),
	);
} catch {
	/* игнорируем */
}

/**
 * Проба RPC: повторяем, пока бэкенд не ответит. Результат — в localStorage
 * 'vrb-probe' (читается снаружи из LevelDB).
 */
const probeBackendCalls = async (): Promise<void> => {
	try {
		const result = await api.ping();
		try {
			localStorage.setItem('vrb-probe', 'ok ' + JSON.stringify(result).slice(0, 200));
		} catch {
			/* игнорируем */
		}
		return;
	} catch (error) {
		try {
			localStorage.setItem('vrb-probe', 'fail ' + String(error).slice(0, 200));
		} catch {
			/* игнорируем */
		}
	}
};

let probeAttempt = 0;
const probeTimer = window.setInterval((): void => {
	probeAttempt += 1;
	void probeBackendCalls();
	if (probeAttempt >= 8) window.clearInterval(probeTimer);
}, 15000);
window.setTimeout((): void => void probeBackendCalls(), 5000);

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

const g = globalThis as unknown as { SP_REACTDOM?: unknown };
console.error('[VRTEST] bundle loaded, reactDom=' + typeof g.SP_REACTDOM);

/**
 * Самопроверка связи с Lua-бэкендом: пишет в консоль Steam UI одну строку,
 * по которой видно, работает ли RPC. Полезно и пользователю при разборе проблем.
 */
const probeBackend = async (): Promise<void> => {
	for (let attempt = 1; attempt <= 8; attempt++) {
		try {
			const result = await api.ping();
			console.info('[Version Rollback] backend ok ' + JSON.stringify(result));
			try {
				localStorage.setItem('vrb-probe', 'ok ' + JSON.stringify(result));
			} catch {
				/* игнорируем */
			}
			api.debugNote('backend ok ' + JSON.stringify(result)).catch((): void => undefined);
			return;
		} catch (error) {
			if (attempt === 8) {
				console.error('[Version Rollback] backend недоступен: ' + String(error));
				try {
					localStorage.setItem('vrb-probe', 'fail ' + String(error));
				} catch {
					/* игнорируем */
				}
				api.debugNote('backend fail: ' + String(error)).catch((): void => undefined);
				return;
			}
			await new Promise((resolve) => setTimeout(resolve, 1500));
		}
	}
};

export default definePlugin(() => ({
	title: 'Version Rollback',
	icon: <Icon />,
	content: (
		<div id="version-rollback-settings-root" style={{ padding: '8px 0', fontSize: '13px', lineHeight: 1.5 }}>
			<div>Панель выбора версии теперь в разделе «Библиотека» — кнопка в правом нижнем углу.</div>
			<div style={{ opacity: 0.7, fontSize: '12px', marginTop: '6px' }}>
				Здесь осталась только справка: настройки Millennium не место для выбора версии игры. Для конкретной игры откройте
				Свойства → «Версии и бета-версии».
			</div>
		</div>
	),
}));

// Важно: тело definePlugin Millennium вызывает лениво (при открытии своей страницы
// настроек), поэтому вставку в свойства и самопроверку RPC запускаем сразу при
// загрузке бандла.
try {
	// временно выключено для диагностики
	void mountDock;
} catch (error) {
	console.error('[Version Rollback] не удалось поставить кнопку в библиотеке:', error);
}

try {
	void startBetasSection;
} catch (error) {
	console.error('[Version Rollback] не удалось запустить вставку в свойства игры:', error);
}

void probeBackend();
