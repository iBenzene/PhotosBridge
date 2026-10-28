// tests/app.test.ts

import { afterEach, beforeEach, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import request from 'supertest';
import { createApp } from '../src/app.js';
import { PhotosBridgeDatabase } from '../src/database.js';
import { DeviceHub } from '../src/device-hub.js';

const adminKey = 'test-admin-key-with-enough-entropy';
let database: PhotosBridgeDatabase;
let hub: DeviceHub;

beforeEach(() => {
    database = new PhotosBridgeDatabase(':memory:');
    database.seedAdminKey(adminKey);
    hub = new DeviceHub(database);
});

afterEach(() => database.close());

const app = () =>
    createApp({
        config: {
            adminKey,
            databasePath: ':memory:',
            port: 0,
            publicBaseURL: 'https://bridge.test'
        },
        database,
        hub
    });

describe('Photos Bridge Server', () => {
    it('serves the admin panel and restricts management to administrators', async () => {
        await request(app()).get('/').expect(302).expect('Location', '/ui/');
        const page = await request(app()).get('/ui/').expect(200);
        assert.match(page.text, /id="app"/);
        assert.match(
            page.headers['content-security-policy'] ?? '',
            /frame-ancestors 'none'/
        );
        assert.equal(page.headers['cache-control'], 'no-store');
        assert.match(page.text, /\/ui\/assets\/.+\.js/);
        const assets = [
            ...page.text.matchAll(/(?:src|href)="(\/ui\/assets\/[^"]+)"/g)
        ];
        assert.ok(assets.length >= 3);
        for (const asset of assets) {
            await request(app()).get(asset[1]!).expect(200);
        }
        await request(app()).get('/admin/').expect(404);
        await request(app()).get('/ui/api/session').expect(401);
        await request(app()).post('/ui/api/pairing').expect(401);
        await request(app()).post('/ui/api/pairing/status').expect(401);
        await request(app()).delete('/ui/api/pairing').expect(401);
        await request(app()).patch('/ui/api/devices/anything').expect(401);
        const reader = database.createAPIKey('reader', ['library.read']);
        await request(app())
            .post('/ui/api/login')
            .set('Origin', 'https://bridge.test')
            .send({ key: reader.key })
            .expect(403);
        await request(app())
            .post('/ui/api/login')
            .set('Origin', 'https://bridge.test')
            .send({ key: adminKey })
            .expect(200);
    });

    it('tracks pairing completion, expiry and cancellation without sharing device credentials', async () => {
        const client = request(app());
        const login = await client
            .post('/ui/api/login')
            .set('Origin', 'https://bridge.test')
            .send({ key: adminKey })
            .expect(200);
        const cookie = (
            login.headers['set-cookie'] as unknown as string[]
        )[0]!.split(';')[0]!;
        const created = await client
            .post('/ui/api/pairing')
            .set('Cookie', cookie)
            .set('Origin', 'https://bridge.test')
            .expect(201);
        assert.match(created.body.qr, /^data:image\/png;base64,/);
        assert.equal(created.body.server_url, 'https://bridge.test');
        const payload = { pairing_token: created.body.pairing_token };
        const status = async () =>
            (
                await client
                    .post('/ui/api/pairing/status')
                    .set('Cookie', cookie)
                    .set('Origin', 'https://bridge.test')
                    .send(payload)
                    .expect(200)
            ).body.status;
        assert.equal(await status(), 'pending');
        const paired = await client
            .post('/device/v1/pair')
            .send({
                ...payload,
                app_version: '1',
                display_name: 'Phone A',
                protocol_version: 1
            })
            .expect(201);
        assert.equal(await status(), 'paired');
        await client
            .post('/device/v1/pair')
            .send({
                ...payload,
                app_version: '1',
                display_name: 'Phone B',
                protocol_version: 1
            })
            .expect(409);
        await client
            .patch(`/ui/api/devices/${paired.body.device_id}`)
            .set('Cookie', cookie)
            .set('Origin', 'https://bridge.test')
            .send({ display_name: '  主力手机  ' })
            .expect(204);
        assert.equal(
            database.getDevice(paired.body.device_id)?.display_name,
            '主力手机'
        );
        await client
            .patch(`/ui/api/devices/${paired.body.device_id}`)
            .set('Cookie', cookie)
            .set('Origin', 'https://bridge.test')
            .send({ display_name: ' ' })
            .expect(400);
        await client
            .delete(`/ui/api/devices/${paired.body.device_id}`)
            .set('Cookie', cookie)
            .set('Origin', 'https://bridge.test')
            .expect(204);
        assert.equal(
            database.authenticateDevice(
                paired.body.device_id,
                paired.body.device_secret
            ),
            false
        );
        const second = await client
            .post('/ui/api/pairing')
            .set('Cookie', cookie)
            .set('Origin', 'https://bridge.test')
            .expect(201);
        await client
            .delete('/ui/api/pairing')
            .set('Cookie', cookie)
            .set('Origin', 'https://bridge.test')
            .send({ pairing_token: second.body.pairing_token })
            .expect(204);
        assert.equal(
            database.pairingStatus(second.body.pairing_token),
            'invalid'
        );
        const expired = database.createPairingSession(-1);
        assert.equal(database.pairingStatus(expired.token), 'expired');
        await client
            .post('/device/v1/pair')
            .send({
                app_version: '1',
                display_name: 'Phone',
                pairing_token: expired.token,
                protocol_version: 1
            })
            .expect(410);
    });

    it('reports version and protocol health without authentication', async () => {
        const response = await request(app()).get('/health').expect(200);
        assert.equal(response.body.version, '0.1.0');
        assert.equal(response.body.protocol_version, 1);
    });

    it('protects device APIs', async () => {
        await request(app()).get('/api/v1/devices').expect(401);
    });

    it('keeps the active bootstrap admin key aligned with the current server session', () => {
        const rotatedKey = 'rotated-admin-key-with-enough-entropy';
        database.seedAdminKey(rotatedKey);

        assert.equal(database.authenticateAPIKey(adminKey), null);
        assert.deepEqual(database.authenticateAPIKey(rotatedKey)?.scopes, [
            'admin',
            'library.read',
            'plans.write'
        ]);
    });

    it('pairs a device exactly once and lists it', async () => {
        const pairing = await request(app())
            .post('/api/v1/pairing-sessions')
            .set('Authorization', `Bearer ${adminKey}`)
            .expect(201);
        assert.equal('qr_payload' in pairing.body, false);
        assert.equal('pairing_session_id' in pairing.body, false);

        const body = {
            app_version: '0.1.0',
            capabilities: ['library.metadata.read', 'library.metadata.read'],
            display_name: 'Test iPhone',
            pairing_token: pairing.body.pairing_token,
            protocol_version: 1
        };
        const paired = await request(app())
            .post('/device/v1/pair')
            .send(body)
            .expect(201);
        assert.match(paired.body.device_id, /^device_/);
        assert.match(paired.body.device_secret, /^pbd_/);

        const duplicate = await request(app())
            .post('/device/v1/pair')
            .send(body)
            .expect(409);
        assert.equal(duplicate.body.error.code, 'PAIRING_ALREADY_USED');

        const devices = await request(app())
            .get('/api/v1/devices')
            .set('Authorization', `Bearer ${adminKey}`)
            .expect(200);
        assert.equal(devices.body.devices.length, 1);
        assert.equal(devices.body.devices[0].display_name, 'Test iPhone');
        assert.deepEqual(devices.body.devices[0].capabilities, [
            'library.metadata.read'
        ]);
        assert.equal(devices.body.devices[0].online, false);
    });

    it('returns a stable offline error for bridge reads', async () => {
        const session = database.createPairingSession();
        const paired = database.pairDevice({
            appVersion: '0.1.0',
            capabilities: ['library.metadata.read'],
            displayName: 'Offline iPad',
            protocolVersion: 1,
            token: session.token
        });
        const response = await request(app())
            .get(`/api/v1/devices/${paired.deviceID}/assets`)
            .set('Authorization', `Bearer ${adminKey}`)
            .expect(503);
        assert.equal(response.body.error.code, 'DEVICE_OFFLINE');
    });

    it('rejects bridge reads that were not granted during pairing', async () => {
        const session = database.createPairingSession();
        const paired = database.pairDevice({
            appVersion: '0.1.0',
            capabilities: [],
            displayName: 'Restricted iPhone',
            protocolVersion: 1,
            token: session.token
        });
        const response = await request(app())
            .get(`/api/v1/devices/${paired.deviceID}/assets`)
            .set('Authorization', `Bearer ${adminKey}`)
            .expect(403);
        assert.equal(response.body.error.code, 'CAPABILITY_NOT_GRANTED');
    });

    it('forwards thumbnail content mode and keeps fill as the default', async () => {
        const session = database.createPairingSession();
        const paired = database.pairDevice({
            appVersion: '0.1.0',
            capabilities: ['assets.thumbnail.read'],
            displayName: 'Thumbnail iPhone',
            protocolVersion: 1,
            token: session.token
        });
        const requests: unknown[] = [];
        hub.request = async (...[, , payload]) => {
            requests.push(payload);
            return {
                data_base64: Buffer.from('jpeg').toString('base64'),
                mime_type: 'image/jpeg'
            };
        };

        await request(app())
            .get(`/api/v1/devices/${paired.deviceID}/assets/asset-1/thumbnail`)
            .set('Authorization', `Bearer ${adminKey}`)
            .expect(200);
        await request(app())
            .get(
                `/api/v1/devices/${paired.deviceID}/assets/asset-1/thumbnail?max_dimension=518&content_mode=fit`
            )
            .set('Authorization', `Bearer ${adminKey}`)
            .expect(200);

        assert.deepEqual(requests, [
            { asset_id: 'asset-1', content_mode: 'fill', max_dimension: 768 },
            { asset_id: 'asset-1', content_mode: 'fit', max_dimension: 518 }
        ]);
    });

    it('rejects invalid thumbnail content modes before contacting the device', async () => {
        const session = database.createPairingSession();
        const paired = database.pairDevice({
            appVersion: '0.1.0',
            capabilities: ['assets.thumbnail.read'],
            displayName: 'Thumbnail iPhone',
            protocolVersion: 1,
            token: session.token
        });
        let called = false;
        hub.request = async () => {
            called = true;
            return {};
        };

        const response = await request(app())
            .get(
                `/api/v1/devices/${paired.deviceID}/assets/asset-1/thumbnail?content_mode=stretch`
            )
            .set('Authorization', `Bearer ${adminKey}`)
            .expect(400);

        assert.equal(
            response.body.error.code,
            'INVALID_THUMBNAIL_CONTENT_MODE'
        );
        assert.equal(called, false);
    });

    it('lets an authenticated device revoke its own credential', async () => {
        const session = database.createPairingSession();
        const paired = database.pairDevice({
            appVersion: '0.1.0',
            capabilities: [],
            displayName: 'Retired iPhone',
            protocolVersion: 1,
            token: session.token
        });
        await request(app())
            .post('/device/v1/unpair')
            .set('Authorization', `Bearer ${paired.deviceSecret}`)
            .send({ device_id: paired.deviceID })
            .expect(204);
        assert.equal(
            database.authenticateDevice(paired.deviceID, paired.deviceSecret),
            false
        );
    });

    it('creates a scoped API key and revokes it', async () => {
        const created = await request(app())
            .post('/api/v1/api-keys')
            .set('Authorization', `Bearer ${adminKey}`)
            .send({ name: 'read-only', scopes: ['library.read'] })
            .expect(201);
        assert.match(created.body.api_key, /^pbk_/);
        await request(app())
            .get('/api/v1/devices')
            .set('Authorization', `Bearer ${created.body.api_key}`)
            .expect(200);
        await request(app())
            .delete(`/api/v1/api-keys/${created.body.api_key_id}`)
            .set('Authorization', `Bearer ${adminKey}`)
            .expect(204);
        await request(app())
            .get('/api/v1/devices')
            .set('Authorization', `Bearer ${created.body.api_key}`)
            .expect(401);
    });
});
