// tests/ui-auth.test.ts

import assert from 'node:assert/strict';
import { afterEach, it, mock } from 'node:test';
import { createAuth } from '../ui/auth.js';

afterEach(() => mock.restoreAll());
const session = () => Response.json({ server_url: 'https://bridge.test' });

it('shares startup restoration and does not revalidate on ordinary navigation', async () => {
    let resolve!: (response: Response) => void;
    const fetch = mock.method(
        globalThis,
        'fetch',
        () =>
            new Promise<Response>(done => {
                resolve = done;
            })
    );
    const auth = createAuth();
    const first = auth.restore();
    assert.equal(auth.restore(), first);
    assert.equal(auth.state.status, 'unknown');
    resolve(session());
    await first;
    await auth.restore();
    assert.equal(auth.state.status, 'authenticated');
    assert.equal(fetch.mock.callCount(), 1);
});

it('keeps startup network failures out of the login page and supports retry', async () => {
    const fetch = mock.method(globalThis, 'fetch', async () => {
        throw new TypeError('offline');
    });
    const auth = createAuth();
    await auth.restore();
    assert.equal(auth.state.status, 'unknown');
    assert.ok(auth.state.error);
    fetch.mock.mockImplementation(async () => session());
    await auth.restore();
    assert.equal(auth.state.status, 'authenticated');
});

it('retains authentication on network, 500 and 403 errors, invalidating only on 401', async () => {
    const fetch = mock.method(globalThis, 'fetch', async () => session());
    const auth = createAuth();
    await auth.restore();
    for (const status of [500, 403]) {
        fetch.mock.mockImplementation(async () => new Response('', { status }));
        await assert.rejects(auth.api.devices());
        assert.equal(auth.state.status, 'authenticated');
    }
    fetch.mock.mockImplementation(async () => {
        throw new TypeError('offline');
    });
    await assert.rejects(auth.logout());
    assert.equal(auth.state.status, 'authenticated');
    fetch.mock.mockImplementation(
        async () => new Response('', { status: 401 })
    );
    await assert.rejects(auth.api.devices());
    assert.equal(auth.state.status, 'anonymous');
});

it('ignores stale restoration after logout and stale 401 responses after a new login', async () => {
    let resolve!: (response: Response) => void;
    const fetch = mock.method(
        globalThis,
        'fetch',
        () =>
            new Promise<Response>(done => {
                resolve = done;
            })
    );
    const auth = createAuth();
    const restored = auth.restore();
    auth.invalidate();
    resolve(session());
    await restored;
    assert.equal(auth.state.status, 'anonymous');
    const stale = auth.api.devices();
    fetch.mock.mockImplementation(async () => session());
    await auth.login('key');
    resolve(new Response('', { status: 401 }));
    await assert.rejects(stale);
    assert.equal(auth.state.status, 'authenticated');
});

it('automatically re-logs in with a remembered key when the session cookie expires and clears it on logout', async () => {
    const store = new Map<string, string>();
    const storage = {
        getItem: (key: string) => store.get(key) ?? null,
        removeItem: (key: string) => {
            store.delete(key);
        },
        setItem: (key: string, value: string) => {
            store.set(key, value);
        }
    };
    const fetch = mock.method(
        globalThis,
        'fetch',
        async (input: RequestInfo | URL) => {
            if (String(input) === '/ui/api/session') {
                return new Response('', { status: 401 });
            }
            if (String(input) === '/ui/api/login') {
                return session();
            }
            return new Response(null, { status: 204 });
        }
    );
    const first = createAuth(storage);
    await first.login('saved-admin-key', true);
    assert.equal(store.get('photos-bridge:admin-key'), 'saved-admin-key');

    const reopened = createAuth(storage);
    await reopened.restore();
    assert.equal(reopened.state.status, 'authenticated');
    assert.equal(reopened.state.serverUrl, 'https://bridge.test');
    assert.equal(fetch.mock.callCount(), 3);

    await reopened.logout();
    assert.equal(store.has('photos-bridge:admin-key'), false);
    assert.equal(reopened.state.status, 'anonymous');
});
