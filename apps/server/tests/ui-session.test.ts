// tests/ui-session.test.ts

import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, it } from 'node:test';
import request from 'supertest';
import { createApp } from '../src/app.js';
import { PhotosBridgeDatabase } from '../src/database.js';
import { DeviceHub } from '../src/device-hub.js';

const key = 'session-test-admin-key';
const origin = 'https://bridge.test';
let directory: string;
let database: PhotosBridgeDatabase;
const app = () =>
    createApp({
        config: {
            databasePath: path.join(directory, 'test.sqlite'),
            port: 0,
            publicBaseURL: origin
        },
        database,
        hub: new DeviceHub(database)
    });
beforeEach(() => {
    directory = mkdtempSync(path.join(tmpdir(), 'photos-bridge-session-'));
    database = new PhotosBridgeDatabase(path.join(directory, 'test.sqlite'));
    database.seedAdminKey(key);
});
afterEach(() => {
    database.close();
    rmSync(directory, { force: true, recursive: true });
});
const login = async (apiKey = key) => {
    const response = await request(app())
        .post('/ui/api/login')
        .set('Origin', origin)
        .send({ key: apiKey })
        .expect(200);
    return (response.headers['set-cookie'] as unknown as string[])[0]!;
};
const cookie = (value: string) => value.split(';')[0]!;

it('persists hashed sessions across database reopen and renews the cookie and expiry', async () => {
    const header = await login();
    assert.match(header, /HttpOnly/);
    assert.match(header, /Secure/);
    assert.match(header, /SameSite=Strict/);
    assert.match(header, /Path=\/ui/);
    assert.match(header, /Max-Age=604800/);
    const stored = database.connection
        .prepare('SELECT * FROM ui_sessions')
        .get() as { token_hash: string; key_hash: string };
    assert.ok(!header.includes(stored.token_hash));
    assert.notEqual(stored.key_hash, key);
    database.connection
        .prepare('UPDATE ui_sessions SET expires_at = ?')
        .run(Date.now() + 10000);
    database.close();
    database = new PhotosBridgeDatabase(path.join(directory, 'test.sqlite'));
    const restored = await request(app())
        .get('/ui/api/session')
        .set('Cookie', cookie(header))
        .expect(200);
    assert.equal(restored.body.server_url, origin);
    assert.ok(restored.headers['set-cookie']);
    const row = database.connection
        .prepare('SELECT expires_at FROM ui_sessions')
        .get() as { expires_at: number };
    assert.ok(row.expires_at > Date.now() + 6 * 86400000);
    assert.ok(row.expires_at <= Date.now() + 7 * 86400000);
    await request(app())
        .get('/ui/api/devices')
        .set('Cookie', cookie(header))
        .expect(200);
    await request(app())
        .get('/api/v1/devices')
        .set('Cookie', cookie(header))
        .expect(401);
    await request(app())
        .get('/api/v1/devices')
        .set('Authorization', `Bearer ${key}`)
        .expect(200);
});

it('rejects cross-origin and missing-origin writes including login and logout', async () => {
    const client = request(app());
    await client.post('/ui/api/login').send({ key }).expect(403);
    await client
        .post('/ui/api/login')
        .set('Origin', 'https://evil.test')
        .send({ key })
        .expect(403);
    const session = cookie(await login());
    await client.post('/ui/api/pairing').set('Cookie', session).expect(403);
    await client
        .post('/ui/api/logout')
        .set('Cookie', session)
        .set('Origin', 'https://evil.test')
        .expect(403);
    await client.get('/ui/api/session').set('Cookie', session).expect(200);
    await client
        .post('/ui/api/logout')
        .set('Cookie', session)
        .set('Origin', origin)
        .expect(204);
    await client.get('/ui/api/session').set('Cookie', session).expect(401);
});

it('invalidates expired, revoked and rotated-key sessions and replaces sessions on login', async () => {
    const first = cookie(await login());
    const replacement = await request(app())
        .post('/ui/api/login')
        .set('Cookie', first)
        .set('Origin', origin)
        .send({ key })
        .expect(200);
    await request(app())
        .get('/ui/api/session')
        .set('Cookie', first)
        .expect(401);
    const second = cookie(
        (replacement.headers['set-cookie'] as unknown as string[])[0]!
    );
    database.seedAdminKey('replacement-admin-key');
    await request(app())
        .get('/ui/api/session')
        .set('Cookie', second)
        .expect(401);
    const admin = database.createAPIKey('another admin', ['admin']);
    const third = cookie(await login(admin.key));
    database.revokeAPIKey(admin.id);
    await request(app())
        .get('/ui/api/session')
        .set('Cookie', third)
        .expect(401);
    const fourth = cookie(await login('replacement-admin-key'));
    database.connection.prepare('UPDATE ui_sessions SET expires_at = 0').run();
    await request(app())
        .get('/ui/api/session')
        .set('Cookie', fourth)
        .expect(401);
});

it('limits login attempts and preserves SPA and API routing boundaries', async () => {
    const client = request(app());
    for (let attempt = 0; attempt < 10; attempt += 1) {
        await client
            .post('/ui/api/login')
            .set('Origin', origin)
            .send({ key: 'wrong' })
            .expect(401);
    }
    await client
        .post('/ui/api/login')
        .set('Origin', origin)
        .send({ key })
        .expect(429);
    await client.get('/ui/login').expect(200).expect('Content-Type', /html/);
    await client.get('/ui/assets/missing.js').expect(404);
    await client
        .get('/ui/api/missing')
        .set('Cookie', cookie(await login()))
        .expect(404)
        .expect('Content-Type', /json/);
});
