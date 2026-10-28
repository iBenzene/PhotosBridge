// ui/api.ts

export interface Device {
    device_id: string;
    display_name: string;
    online: boolean;
    last_seen_at: string | null;
    app_version: string;
}

export interface Pairing {
    pairing_token: string;
    expires_at: string;
    qr: string;
}

export type PairingStatus = 'pending' | 'paired' | 'expired' | 'invalid';

/**
 * 封装管理后台与服务端通信的 HTTP 接口客户端。
 * 使用同源 Cookie 会话, 并对异常响应码进行统一处理。
 */
export class ApiError extends Error {
    constructor(
        readonly status: number,
        message: string
    ) {
        super(message);
    }
}

export const createAdminApi = (
    onUnauthorized = () => {},
    version = () => 0
) => {
    const request = async <T>(
        path: string,
        method = 'GET',
        body?: unknown
    ): Promise<T> => {
        const revision = version();
        const response = await fetch(path, {
            body: body === undefined ? undefined : JSON.stringify(body),
            cache: 'no-store',
            credentials: 'same-origin',
            headers: {
                'Content-Type': 'application/json'
            },
            method,
            signal: AbortSignal.timeout(15_000)
        });
        if (!response.ok) {
            if (response.status === 401) {
                if (
                    path !== '/ui/api/login' &&
                    path !== '/ui/api/session' &&
                    revision === version()
                ) {
                    onUnauthorized();
                }
                throw new ApiError(
                    401,
                    '登录凭据无效或会话已失效，请重新登录。'
                );
            }
            if (response.status === 403) {
                throw new ApiError(403, '没有操作权限或请求来源不受信任。');
            }
            if (response.status === 429) {
                throw new Error('操作过于频繁，请稍后再试。');
            }
            throw new Error(`操作失败（${response.status}），请重试。`);
        }
        return response.status === 204 ? (undefined as T) : response.json();
    };
    const tokenBody = (pairing: Pairing) => ({
        pairing_token: pairing.pairing_token
    });
    return {
        cancelPairing: (pairing: Pairing) =>
            request<void>('/ui/api/pairing', 'DELETE', tokenBody(pairing)),
        createPairing: () => request<Pairing>('/ui/api/pairing', 'POST', {}),
        devices: () => request<{ devices: Device[] }>('/ui/api/devices'),
        login: (key: string) =>
            request<{ server_url: string }>('/ui/api/login', 'POST', { key }),
        logout: () => request<void>('/ui/api/logout', 'POST'),
        pairingStatus: (pairing: Pairing) =>
            request<{ status: PairingStatus }>(
                '/ui/api/pairing/status',
                'POST',
                tokenBody(pairing)
            ),
        remove: (device: Device) =>
            request<void>(
                `/ui/api/devices/${encodeURIComponent(device.device_id)}`,
                'DELETE'
            ),
        rename: (device: Device, name: string) =>
            request<void>(
                `/ui/api/devices/${encodeURIComponent(device.device_id)}`,
                'PATCH',
                {
                    display_name: name.trim()
                }
            ),
        session: () => request<{ server_url: string }>('/ui/api/session')
    };
};

export type AdminApi = ReturnType<typeof createAdminApi>;
