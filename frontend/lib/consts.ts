/** Общие константы фронтенда. */

/** Версия плагина (показывается в интерфейсе и в millennium.toml). */
export const PLUGIN_VERSION = '0.6.0';

/** Настройка, в которой хранится решение пользователя по сбору: yes / no / ''. */
export const CONSENT_KEY = 'collect_consent';

/**
 * Настройка с отметкой, что вопрос уже задавали. Храним НЕ версию плагина,
 * а «поколение» согласия: вопрос задаётся ровно один раз и повторяется только
 * если изменится САТ состав собираемых данных (тогда меняется CONSENT_SCOPE).
 */
export const CONSENT_SHOWN_KEY = 'consent_shown_for';
export const CONSENT_SCOPE = 'scope-1';

/** Репа, куда отправляются Issue со собранными метаданными. */
export const ISSUE_REPO = 'Stintik-123/steam-version-rollback';
