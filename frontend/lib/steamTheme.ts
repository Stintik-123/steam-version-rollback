/**
 * Палитра Steam — сине-серая, как у клиента (панели #1b2838, границы #2a475e,
 * акцент #66c0f4 / #1a9fff, текст #c7d5e0). Используется и в панели настроек,
 * и в карточке согласия в библиотеке, чтобы плагин не выглядел «чужой панелью».
 */

export const steamTheme = {
	/** фон панели Steam (тёмно-сине-серый) */
	panel: '#1b2838',
	/** фон вложенного блока/строки */
	panelAlt: '#16202d',
	row: '#22364b',
	/** границы и разделители */
	border: '#2a475e',
	/** светло-синий акцент Steam (ссылки, заголовки) */
	accent: '#66c0f4',
	/** основная синяя кнопка Steam */
	accentStrong: '#1a9fff',
	/** основной текст */
	text: '#c7d5e0',
	/** приглушённый текст */
	muted: '#8f98a0',
	ok: '#a4d007',
	err: '#e06c75',
} as const;

/** Кнопка Steam: синяя, со скруглением 4px. */
export const steamButton = (primary = false): React.CSSProperties => ({
	padding: '7px 14px',
	borderRadius: 4,
	border: primary ? 'none' : `1px solid ${steamTheme.border}`,
	cursor: 'pointer',
	fontWeight: 600,
	font: 'inherit',
	background: primary
		? `linear-gradient(180deg, ${steamTheme.accentStrong}, #1583c6)`
		: steamTheme.row,
	color: primary ? '#ffffff' : steamTheme.text,
});
