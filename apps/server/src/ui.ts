// src/ui.ts

import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import express, { type RequestHandler } from 'express';
import QRCode from 'qrcode';
import type { AppDependencies } from './app.js';
import { createUISessions } from './ui-session.js';

/**
 * 挂载 Web 控制台静态资源与管理端专用 API 路由
 */
export const mountUI = (
    app: express.Express,
    { config, database, hub }: AppDependencies,
    loginLimit: RequestHandler
): void => {
    // 兼容源码运行开发模式与打包后的生产部署模式, 自动定位静态资源目录
    const fromSource = existsSync(new URL('../package.json', import.meta.url));
    const directory = fileURLToPath(
        new URL(fromSource ? '../dist/ui/' : '../ui/', import.meta.url)
    );
    app.get('/', (...[, response]) => response.redirect('/ui/'));
    // 注入安全响应头, 禁用浏览器资源缓存并开启严格的内容安全策略 (CSP)
    app.use('/ui', (...[, response, next]) => {
        response.setHeader('Cache-Control', 'no-store');
        response.setHeader('Referrer-Policy', 'no-referrer');
        response.setHeader('X-Content-Type-Options', 'nosniff');
        response.setHeader(
            'Content-Security-Policy',
            "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
        );
        next();
    });
    const sessions = createUISessions(database, config.publicBaseURL);
    app.post('/ui/api/login', loginLimit, sessions.source, sessions.login);
    app.post('/ui/api/logout', sessions.source, sessions.logout);
    app.use('/ui/api', sessions.authorize, sessions.source);
    app.get('/ui/api/session', (...[, response]) =>
        response.json({ server_url: config.publicBaseURL })
    );
    app.get('/ui/api/devices', (...[, response]) => {
        response.json({
            devices: database.listDevices().map(device => ({
                app_version: device.app_version,
                device_id: device.id,
                display_name: device.display_name,
                last_seen_at: device.last_seen_at,
                online: hub.isOnline(device.id)
            }))
        });
    });
    app.delete('/ui/api/devices/:deviceID', (request, response) => {
        const deviceID = String(request.params.deviceID);
        if (!database.revokeDevice(deviceID)) {
            response.status(404).json({ error: { code: 'DEVICE_NOT_FOUND' } });
            return;
        }
        hub.disconnect(deviceID);
        response.sendStatus(204);
    });
    // 创建新的设备配对会话, 并同步生成用于手机端扫码的 Data URL 二维码
    app.post('/ui/api/pairing', async (...[, response]) => {
        const session = database.createPairingSession();
        const payload = {
            expires_at: session.expiresAt,
            pairing_token: session.token,
            server_url: config.publicBaseURL
        };
        response.status(201).json({
            ...payload,
            qr: await QRCode.toDataURL(JSON.stringify(payload), {
                margin: 4,
                width: 360
            })
        });
    });
    app.post('/ui/api/pairing/status', (request, response) => {
        response.json({
            status: database.pairingStatus(
                String(request.body?.pairing_token ?? '')
            )
        });
    });
    app.delete('/ui/api/pairing', (request, response) => {
        database.cancelPairing(String(request.body?.pairing_token ?? ''));
        response.sendStatus(204);
    });
    // 更新指定设备的展示名称, 限制长度且不可为空
    app.patch('/ui/api/devices/:deviceID', (request, response) => {
        const name = request.body?.display_name;
        if (
            typeof name !== 'string' ||
            !name.trim() ||
            name.trim().length > 80
        ) {
            response
                .status(400)
                .json({ error: { code: 'INVALID_DEVICE_NAME' } });
            return;
        }
        const result = database.connection
            .prepare(
                'UPDATE devices SET display_name = ? WHERE id = ? AND revoked_at IS NULL'
            )
            .run(name.trim(), String(request.params.deviceID));
        response.sendStatus(result.changes ? 204 : 404);
    });
    app.use('/ui/api', (...[, response]) =>
        response.status(404).json({ error: { code: 'NOT_FOUND' } })
    );
    app.use('/ui', express.static(directory, { index: 'index.html' }));
    app.get(['/ui/login', '/ui/login/'], (...[, response]) =>
        response.sendFile(`${directory}/index.html`)
    );
};
