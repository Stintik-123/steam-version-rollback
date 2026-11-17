/**
 * Панель Version Rollback прямо в разделе «Библиотека».
 *
 * Зачем: настройки Millennium — не то место, где выбирают версию игры. Пользователь
 * работает в библиотеке, поэтому там и висит компактная кнопка, раскрывающая панель
 * поверх страницы. Тот же приём, что и у баннера согласия: DOM-инъекция + ReactDOM
 * Steam, без патчей минифицированного JS.
 */

import { useState } from 'react';

import { VersionPanel } from './VersionPanel';

const pillStyle = {
	position: 'fixed' as const,
	right: '24px',
	bottom: '24px',
	zIndex: 2147483646,
	padding: '10px 14px',
	borderRadius: '8px',
	border: '1px solid rgba(255,255,255,.18)',
	background: 'rgba(23,26,33,.94)',
	color: '#dcdedf',
	font: '13px "Motiva Sans", Arial, sans-serif',
	cursor: 'pointer',
	boxShadow: '0 6px 24px rgba(0,0,0,.45)',
};

const panelStyle = {
	position: 'fixed' as const,
	right: '24px',
	bottom: '24px',
	zIndex: 2147483647,
	width: 'min(560px, calc(100vw - 48px))',
	maxHeight: 'calc(100vh - 120px)',
	display: 'flex',
	flexDirection: 'column' as const,
	borderRadius: '10px',
	border: '1px solid rgba(255,255,255,.16)',
	background: 'rgba(23,26,33,.98)',
	color: '#dcdedf',
	boxShadow: '0 12px 40px rgba(0,0,0,.55)',
	font: '13px "Motiva Sans", Arial, sans-serif',
};

const headerStyle = {
	display: 'flex',
	alignItems: 'center',
	justifyContent: 'space-between',
	padding: '10px 14px',
	borderBottom: '1px solid rgba(255,255,255,.1)',
	fontWeight: 600,
};

const closeStyle = {
	background: 'transparent',
	border: 'none',
	color: '#8f98a0',
	fontSize: '18px',
	lineHeight: '18px',
	cursor: 'pointer',
	padding: '0 4px',
};

const bodyStyle = {
	overflowY: 'auto' as const,
	padding: '12px 14px 16px',
};

export const LibraryDock = () => {
	const [open, setOpen] = useState(false);

	if (!open) {
		return (
			<button type="button" style={pillStyle} onClick={() => setOpen(true)} title="Выбрать версию игры">
				Version Rollback
			</button>
		);
	}

	return (
		<div style={panelStyle}>
			<div style={headerStyle}>
				<span>Version Rollback</span>
				<button type="button" style={closeStyle} onClick={() => setOpen(false)} title="Свернуть">
					×
				</button>
			</div>
			<div style={bodyStyle}>
				<VersionPanel context="library" />
			</div>
		</div>
	);
};
