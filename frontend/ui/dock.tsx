/**
 * Кнопка Version Rollback в разделе «Библиотека» — на чистом DOM.
 *
 * Почему без React: оболочка панели не должна зависеть от SP_REACTDOM. Если у
 * Steam в этой сборке нет нужного API, кнопка всё равно обязана появиться —
 * иначе пользователь просто не находит плагин. React используется только внутри
 * раскрытой панели, и его отсутствие показывается текстом.
 *
 * ВАЖНО (стабильность): здесь НЕТ setInterval. Раньше кнопка пересоздавалась
 * интервалом каждые 1.5 с — теперь её наличие проверяет MutationObserver из
 * inject.tsx и зовёт ensureDock() только когда кнопку действительно выкинули.
 */

import { PanelErrorBoundary } from './PanelErrorBoundary';
import { VersionPanel } from './VersionPanel';

const DOCK_ID = 'version-rollback-dock';
const PANEL_ID = 'version-rollback-dock-panel';
const SETTINGS_ROOT_ID = 'version-rollback-settings-root';

const buttonCss =
	'padding:10px 14px;border-radius:8px;border:1px solid rgba(255,255,255,.18);' +
	'background:rgba(23,26,33,.94);color:#dcdedf;font:13px "Motiva Sans",Arial,sans-serif;' +
	'cursor:pointer;box-shadow:0 6px 24px rgba(0,0,0,.45);';

const panelCss =
	'display:flex;flex-direction:column;width:min(560px,calc(100vw - 48px));' +
	'max-height:calc(100vh - 120px);border-radius:10px;border:1px solid rgba(255,255,255,.16);' +
	'background:rgba(23,26,33,.98);color:#dcdedf;box-shadow:0 12px 40px rgba(0,0,0,.55);' +
	'font:13px "Motiva Sans",Arial,sans-serif;overflow:hidden;';

const headerCss =
	'display:flex;align-items:center;justify-content:space-between;padding:10px 14px;' +
	'border-bottom:1px solid rgba(255,255,255,.1);font-weight:600;';

const bodyCss = 'overflow-y:auto;padding:12px 14px 16px;';

const closeCss =
	'background:transparent;border:none;color:#8f98a0;font-size:18px;line-height:18px;' +
	'cursor:pointer;padding:0 4px;';

type ReactDom = {
	createRoot?: (el: Element) => { render: (node: unknown) => void; unmount: () => void } | null;
	render?: (node: unknown, el: Element) => void;
	unmountComponentAtNode?: (el: Element) => void;
};

const reactDom = (): ReactDom | undefined => (globalThis as unknown as { SP_REACTDOM?: ReactDom }).SP_REACTDOM;

let panelRoot: { unmount: () => void } | null = null;

export const closePanel = (): void => {
	document.getElementById(PANEL_ID)?.remove();
	try {
		panelRoot?.unmount();
	} catch {
		/* панель могла не смонтироваться */
	}
	panelRoot = null;
};

const openPanel = (container: HTMLElement): void => {
	if (document.getElementById(PANEL_ID)) return;

	const panel = document.createElement('div');
	panel.id = PANEL_ID;
	panel.style.cssText = panelCss;

	const header = document.createElement('div');
	header.style.cssText = headerCss;
	const title = document.createElement('span');
	title.textContent = 'Version Rollback';
	const close = document.createElement('button');
	close.type = 'button';
	close.textContent = '×';
	close.title = 'Свернуть';
	close.style.cssText = closeCss;
	close.addEventListener('click', () => closePanel());
	header.append(title, close);

	const body = document.createElement('div');
	body.style.cssText = bodyCss;
	body.textContent = 'Загрузка панели…';

	panel.append(header, body);
	container.replaceChildren(panel);

	const dom = reactDom();
	if (!dom) {
		body.textContent = 'Панель недоступна: в этом клиенте нет SP_REACTDOM.';
		return;
	}

	try {
		if (dom.createRoot) {
			const root = dom.createRoot(body);
			if (!root) throw new Error('createRoot вернул null');
			root.render(
				<PanelErrorBoundary onClose={() => closePanel()}>
					<VersionPanel context="library" />
				</PanelErrorBoundary>,
			);
			panelRoot = root;
		} else if (dom.render) {
			const host = document.createElement('div');
			body.replaceChildren(host);
			dom.render(
				<PanelErrorBoundary onClose={() => closePanel()}>
					<VersionPanel context="library" />
				</PanelErrorBoundary>,
				host,
			);
			panelRoot = { unmount: () => dom.unmountComponentAtNode?.(host) };
		} else {
			body.textContent = 'Панель недоступна: ReactDOM без createRoot/render.';
		}
	} catch (error) {
		// React не смог — показываем текст вместо падения всего окна.
		body.textContent = 'Не удалось открыть панель: ' + String(error);
	}
};

/**
 * Идемпотентно ставит кнопку в правый нижний угол. Вызывается из inject.tsx
 * по событию DOM-мутаций (и один раз при старте), НЕ интервалом.
 */
export const ensureDock = (): void => {
	if (document.getElementById(DOCK_ID)) return;
	// В настройках плагина панель не нужна.
	if (document.getElementById(SETTINGS_ROOT_ID)) return;
	if (!document.body) return;

	const container = document.createElement('div');
	container.id = DOCK_ID;
	container.style.cssText =
		'position:fixed;right:24px;bottom:24px;z-index:2147483646;display:flex;flex-direction:column;align-items:flex-end;';

	const button = document.createElement('button');
	button.type = 'button';
	button.textContent = 'Version Rollback';
	button.title = 'Выбрать версию игры';
	button.style.cssText = buttonCss;
	button.addEventListener('click', () => {
		if (document.getElementById(PANEL_ID)) closePanel();
		else openPanel(container);
	});

	container.append(button);
	document.body.append(container);
	console.info('[Version Rollback] кнопка добавлена в библиотеку');
};

/** Убрать кнопку и панель: открыты настройки плагина или UI выгружается. */
export const removeDock = (): void => {
	closePanel();
	document.getElementById(DOCK_ID)?.remove();
};
