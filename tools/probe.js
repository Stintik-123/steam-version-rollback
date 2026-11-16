/**
 * Диагностика клиента Steam для Version Rollback.
 *
 * Куда вставлять: Steam → DevTools окна SharedJSContext
 * (Millennium: Настройки → Developer → Open SharedJSContext DevTools),
 * вкладка Console. Скрипт ничего не меняет — только читает.
 *
 * Зачем: панель плагина работает без хуков. Хуки (backend/patches.lua) нужны
 * только чтобы встроить блок в штатные окна Steam, и их приходится подбирать
 * под конкретную сборку клиента. Вывод этого скрипта — исходные данные для
 * такого подбора.
 */
(() => {
	const out = {};

	// 1. Есть ли вообще вход в консоль Steam (через него идёт download_depot).
	const sc = globalThis.SteamClient;
	out.steamClient = Boolean(sc);
	out.consoleApi = {
		'SteamClient.Console.ExecCommand': typeof sc?.Console?.ExecCommand,
		'SteamClient.System.ExecCommand': typeof sc?.System?.ExecCommand,
		'SteamClient.Console.ExecuteCommand': typeof sc?.Console?.ExecuteCommand,
	};
	out.steamClientNamespaces = sc ? Object.keys(sc).slice(0, 40) : [];

	// 2. Какие chunk-файлы загружены — именно по ним бьют патчи (file = chunk~xxxx.js).
	const chunks = performance
		.getEntriesByType('resource')
		.map((e) => e.name)
		.filter((n) => /chunk~[0-9a-f]+\.js/.test(n))
		.map((n) => n.split('/').pop());
	out.chunks = [...new Set(chunks)].slice(0, 40);

	// 3. Есть ли рядом React-инстанс (нужен, если будем вставлять React-элементы хуком).
	try {
		out.reactRootPresent = Boolean(document.querySelector('#react-root'));
	} catch (error) {
		out.reactRootPresent = `ошибка: ${error}`;
	}

	console.log('[Version Rollback] диагностика:', out);
	console.table(out.consoleApi);
	console.log('chunk-файлы:', out.chunks.join(', ') || '(не найдены)');

	if (!Object.values(out.consoleApi).includes('function')) {
		console.warn(
			'[Version Rollback] ни один вход консоли не найден. Панель плагина всё равно откроется, ' +
				'но скачивание депо работать не будет — пришли этот вывод разработчику.',
		);
	}

	return out;
})();
