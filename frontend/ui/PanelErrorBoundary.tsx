/**
 * Перехватчик ошибок для панели, которая монтируется в UI Steam.
 *
 * Зачем: React-ошибка в нашем дереве не должна ронять страницу клиента. Если
 * панель падает, показываем короткое сообщение и кнопку «свернуть», а Steam
 * продолжает работать.
 */

import { Component, type ErrorInfo, type ReactNode } from 'react';

type Props = { children: ReactNode; onClose?: () => void };
type State = { error: string | null };

export class PanelErrorBoundary extends Component<Props, State> {
	state: State = { error: null };

	static getDerivedStateFromError(error: unknown): State {
		return { error: String(error) };
	}

	componentDidCatch(error: unknown, info: ErrorInfo): void {
		console.error('[Version Rollback] панель упала:', error, info.componentStack);
	}

	render(): ReactNode {
		if (this.state.error) {
			return (
				<div style={{ fontSize: '12px', lineHeight: 1.5, color: '#ffb3b3' }}>
					<div>Version Rollback: панель упала.</div>
					<div style={{ opacity: 0.8, marginTop: '4px', wordBreak: 'break-word' }}>{this.state.error}</div>
					{this.props.onClose && (
						<button
							type="button"
							onClick={this.props.onClose}
							style={{
								marginTop: '8px',
								padding: '6px 10px',
								borderRadius: '6px',
								border: '1px solid rgba(255,255,255,.2)',
								background: 'transparent',
								color: 'inherit',
								cursor: 'pointer',
							}}
						>
							Закрыть
						</button>
					)}
				</div>
			);
		}
		return this.props.children;
	}
}
