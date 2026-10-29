// ui/auth.ts

import { reactive } from 'vue';
import { ApiError, createAdminApi } from './api.js';

const STORAGE_KEY = 'photos-bridge:admin-key';

export interface KeyStorage {
    getItem(key: string): string | null;
    removeItem(key: string): void;
    setItem(key: string, value: string): void;
}

const defaultStorage = (): KeyStorage | undefined => {
    try {
        return typeof localStorage === 'undefined' ? undefined : localStorage;
    } catch {
        return undefined;
    }
};

/**
 * 管理后台认证与会话状态管理工厂
 * 处理本地凭据缓存、会话自动恢复以及登录与登出状态流转
 */
export const createAuth = (
    storage: KeyStorage | undefined = defaultStorage()
) => {
    const state = reactive({
        error: '',
        loading: false,
        serverUrl: '',
        status: 'unknown' as 'unknown' | 'authenticated' | 'anonymous'
    });
    let revision = 0;
    let pending: Promise<void> | undefined;
    const getSavedKey = () => {
        try {
            return storage?.getItem(STORAGE_KEY) ?? '';
        } catch {
            return '';
        }
    };
    const setSavedKey = (key: string) => {
        try {
            storage?.setItem(STORAGE_KEY, key);
        } catch {
            // 忽略浏览器隐私模式或禁用存储时的写入异常
        }
    };
    const clearSavedKey = () => {
        try {
            storage?.removeItem(STORAGE_KEY);
        } catch {
            // 忽略存储清理异常
        }
    };
    const invalidate = () => {
        revision += 1;
        state.status = 'anonymous';
        state.serverUrl = '';
        state.error = '';
    };
    const handleUnauthorized = () => {
        if (getSavedKey()) {
            revision += 1;
            state.status = 'unknown';
            state.error = '';
            void restore();
            return;
        }
        invalidate();
    };
    const api = createAdminApi(handleUnauthorized, () => revision);
    const restore = (): Promise<void> => {
        if (pending) {
            return pending;
        }
        if (state.status !== 'unknown') {
            return Promise.resolve();
        }
        const current = revision;
        state.loading = true;
        state.error = '';
        pending = api
            .session()
            .catch(async error => {
                if (
                    current === revision &&
                    error instanceof ApiError &&
                    error.status === 401
                ) {
                    const savedKey = getSavedKey();
                    if (savedKey) {
                        try {
                            return await api.login(savedKey);
                        } catch (loginError) {
                            if (
                                loginError instanceof ApiError &&
                                (loginError.status === 401 ||
                                    loginError.status === 403)
                            ) {
                                clearSavedKey();
                            } else {
                                throw loginError;
                            }
                        }
                    }
                    state.status = 'anonymous';
                }
                throw error;
            })
            .then(session => {
                if (current === revision) {
                    state.serverUrl = session.server_url;
                    state.status = 'authenticated';
                }
            })
            .catch(error => {
                if (
                    current === revision &&
                    !(error instanceof ApiError && error.status === 401)
                ) {
                    state.error = '暂时无法连接服务器，请重试。';
                }
            })
            .finally(() => {
                state.loading = false;
                pending = undefined;
            });
        return pending;
    };
    const login = async (key: string, remember = false) => {
        const current = ++revision;
        const session = await api.login(key);
        if (remember) {
            setSavedKey(key);
        } else {
            clearSavedKey();
        }
        if (current === revision) {
            state.serverUrl = session.server_url;
            state.status = 'authenticated';
            state.error = '';
        }
    };
    const logout = async () => {
        await api.logout();
        clearSavedKey();
        invalidate();
    };
    return { api, invalidate, login, logout, restore, state };
};

export const auth = createAuth();
