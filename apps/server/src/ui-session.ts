// src/ui-session.ts

import { randomBytes } from 'node:crypto';
import type { CookieOptions, Request, RequestHandler, Response } from 'express';
import { hashSecret, type PhotosBridgeDatabase } from './database.js';

const COOKIE = 'photos_bridge_session';
const TTL = 7 * 24 * 60 * 60 * 1000;

/**
 * 创建 Web 控制台会话管理与安全中间件
 * 负责 HttpOnly Cookie 签名管理、跨站请求防护 (CSRF) 以及会话自动续期
 */
export const createUISessions = (
    database: PhotosBridgeDatabase,
    publicBaseURL: string
) => {
    const options: CookieOptions = {
        httpOnly: true,
        path: '/ui',
        sameSite: 'strict',
        secure: new URL(publicBaseURL).protocol === 'https:'
    };
    const cookieOptions = (request: Request) => ({
        ...options,
        secure: options.secure || request.secure
    });
    const token = (request: Request) => {
        const cookies = (request.headers.cookie ?? '')
            .split(';')
            .map(value => value.trim());
        return (
            cookies
                .find(value => value.startsWith(`${COOKIE}=`))
                ?.slice(COOKIE.length + 1) ?? ''
        );
    };
    const clear = (request: Request, response: Response) =>
        response.clearCookie(COOKIE, cookieOptions(request));
    const remove = (request: Request) => {
        database.connection
            .prepare('DELETE FROM ui_sessions WHERE token_hash = ?')
            .run(hashSecret(token(request)));
    };
    const source: RequestHandler = (request, response, next) => {
        if (['GET', 'HEAD', 'OPTIONS'].includes(request.method)) {
            next();
            return;
        }
        const origin = request.get('Origin');
        const allowed = new Set([
            new URL(publicBaseURL).origin,
            `${request.protocol}://${request.get('host')}`
        ]);
        if (
            !origin ||
            !allowed.has(origin) ||
            request.get('Sec-Fetch-Site') === 'cross-site'
        ) {
            response.status(403).json({ error: { code: 'INVALID_ORIGIN' } });
            return;
        }
        next();
    };
    const login: RequestHandler = (request, response) => {
        const key =
            typeof request.body?.key === 'string' ? request.body.key : '';
        const principal = database.authenticateAPIKey(key);
        if (!principal) {
            response
                .status(401)
                .json({ error: { code: 'AUTHENTICATION_FAILED' } });
            return;
        }
        if (!principal.scopes.includes('admin')) {
            response
                .status(403)
                .json({ error: { code: 'CAPABILITY_NOT_GRANTED' } });
            return;
        }
        const secret = randomBytes(32).toString('base64url');
        const timestamp = Date.now();
        database.connection.transaction(() => {
            remove(request);
            database.connection
                .prepare('DELETE FROM ui_sessions WHERE expires_at <= ?')
                .run(timestamp);
            database.connection
                .prepare(
                    'INSERT INTO ui_sessions (token_hash, key_hash, expires_at) VALUES (?, ?, ?)'
                )
                .run(hashSecret(secret), hashSecret(key), timestamp + TTL);
        })();
        response.cookie(COOKIE, secret, {
            ...cookieOptions(request),
            maxAge: TTL
        });
        response.json({ server_url: publicBaseURL });
    };
    const authorize: RequestHandler = (request, response, next) => {
        const secret = token(request);
        const row = database.connection
            .prepare(
                `SELECT k.scopes_json FROM ui_sessions s
            JOIN api_keys k ON k.key_hash = s.key_hash
            WHERE s.token_hash = ? AND s.expires_at > ? AND k.revoked_at IS NULL`
            )
            .get(hashSecret(secret), Date.now()) as
            { scopes_json: string } | undefined;
        if (
            !row ||
            !(JSON.parse(row.scopes_json) as string[]).includes('admin')
        ) {
            remove(request);
            clear(request, response);
            response.status(401).json({ error: { code: 'SESSION_EXPIRED' } });
            return;
        }
        database.connection
            .prepare(
                'UPDATE ui_sessions SET expires_at = ? WHERE token_hash = ?'
            )
            .run(Date.now() + TTL, hashSecret(secret));
        response.cookie(COOKIE, secret, {
            ...cookieOptions(request),
            maxAge: TTL
        });
        next();
    };
    const logout: RequestHandler = (request, response) => {
        remove(request);
        clear(request, response);
        response.sendStatus(204);
    };
    return { authorize, login, logout, source };
};
