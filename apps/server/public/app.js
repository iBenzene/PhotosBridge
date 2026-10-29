/* global document */
const $ = id => document.getElementById(id);
let key = '';
let pairing = null;
let timer = null;
let polling = false;
let edit = null;
let generation = 0;
let lastDevices = '';
const message = text => {
    $('message').textContent = text;
};
const api = async (path, method = 'GET', body) => {
    const response = await fetch(path, {
        body: body === undefined ? undefined : JSON.stringify(body),
        cache: 'no-store',
        headers: {
            Authorization: `Bearer ${key}`,
            'Content-Type': 'application/json'
        },
        method
    });
    if (!response.ok) {
        if (response.status === 401 || response.status === 403)
            throw new Error('管理员密钥无效或没有管理权限，请重新登录。');
        if (response.status === 429)
            throw new Error('操作过于频繁，请稍后再试。');
        throw new Error(`操作失败（${response.status}），请重试。`);
    }
    return response.status === 204 ? null : response.json();
};
const readableDate = value =>
    value
        ? new Date(value)
              .toLocaleString('zh-CN', {
                  day: '2-digit',
                  hour: '2-digit',
                  hour12: false,
                  minute: '2-digit',
                  month: '2-digit',
                  second: '2-digit',
                  year: 'numeric'
              })
              .replaceAll('/', '-')
        : '尚未连接';
const element = (tag, text, className) => {
    const node = document.createElement(tag);
    node.textContent = text;
    if (className) node.className = className;
    return node;
};
const loadDevices = async () => {
    const auth = key;
    const result = await api('/api/v1/devices');
    if (key !== auth) return;
    const signature = JSON.stringify(result.devices);
    if (signature === lastDevices) return;
    lastDevices = signature;
    $('count').textContent = `已配对设备 (${result.devices.length})`;
    $('devices').replaceChildren();
    if (!result.devices.length) {
        const empty = element('div', '', 'empty');
        empty.append(
            element('h2', '还没有配对的手机'),
            element('p', '点击「添加手机」，扫描二维码即可连接。')
        );
        $('devices').append(empty);
    }
    for (const device of result.devices) {
        const row = element('article', '', 'device');
        const info = element('div', '', 'device-info');
        const title = element('h3', device.display_name);
        title.append(
            element(
                'span',
                device.online ? '● 在线' : '○ 离线',
                device.online ? 'badge online' : 'badge'
            )
        );
        info.append(
            title,
            element('p', `设备 ID：${device.device_id}`),
            element(
                'p',
                `最近连接：${readableDate(device.last_seen_at)} / App ${device.app_version}`
            )
        );
        const actions = element('div', '', 'actions');
        for (const [label, action] of [
            ['重命名', 'rename'],
            ['解除配对', 'remove']
        ]) {
            const button = element(
                'button',
                label,
                action === 'remove' ? 'danger' : 'quiet'
            );
            button.addEventListener('click', () => openEdit(device, action));
            actions.append(button);
        }
        row.append(element('span', '▯', 'phone'), info, actions);
        $('devices').append(row);
    }
};
const openEdit = (device, action) => {
    edit = { action, device };
    const rename = action === 'rename';
    $('edit-title').textContent = rename ? '重命名手机' : '解除配对';
    $('edit-description').textContent = rename
        ? '设置一个便于区分的名称。'
        : `解除「${device.display_name}」的配对后，这台手机将断开连接。再次使用需要重新扫码配对，不会删除手机照片。`;
    $('device-name').hidden = $('name-label').hidden = !rename;
    $('device-name').required = rename;
    $('device-name').value = device.display_name;
    $('confirm-edit').textContent = rename ? '保存' : '解除配对';
    $('confirm-edit').className = rename ? '' : 'danger';
    $('edit-error').textContent = '';
    $('edit-dialog').showModal();
};
$('cancel-edit').onclick = () => $('edit-dialog').close();
$('edit-form').onsubmit = async event => {
    event.preventDefault();
    $('confirm-edit').disabled = true;
    try {
        if (edit.action === 'rename')
            await api(
                `/admin/api/devices/${encodeURIComponent(edit.device.device_id)}`,
                'PATCH',
                {
                    display_name: $('device-name').value
                }
            );
        else
            await api(
                `/api/v1/devices/${encodeURIComponent(edit.device.device_id)}`,
                'DELETE'
            );
        $('edit-dialog').close();
        await loadDevices();
        message('');
    } catch (error) {
        $('edit-error').textContent = error.message;
    } finally {
        $('confirm-edit').disabled = false;
    }
};
const clearQR = text => {
    $('qr').hidden = true;
    $('qr').removeAttribute('src');
    $('qr-placeholder').hidden = false;
    $('qr-placeholder').textContent = text;
};
const cancelPairing = async () => {
    if (!pairing) return;
    const current = pairing;
    await api('/admin/api/pairing', 'DELETE', {
        pairing_token: current.pairing_token
    });
    if (pairing === current) pairing = null;
};
const newPairing = async () => {
    $('new-pair').disabled = true;
    clearQR('正在生成二维码...');
    $('pair-status').textContent = '';
    const revision = ++generation;
    try {
        await cancelPairing();
        const created = await api('/admin/api/pairing', 'POST', {});
        if (revision !== generation) {
            await api('/admin/api/pairing', 'DELETE', {
                pairing_token: created.pairing_token
            });
            return;
        }
        pairing = created;
        $('qr').src = pairing.qr;
        $('qr').hidden = false;
        $('qr-placeholder').hidden = true;
        updateCountdown();
    } catch (error) {
        clearQR('二维码未生成');
        $('pair-status').textContent = error.message;
    } finally {
        $('new-pair').disabled = false;
    }
};
const updateCountdown = () => {
    if (!pairing || !$('pair-dialog').open) return;
    const seconds = Math.max(
        0,
        Math.ceil((Date.parse(pairing.expires_at) - Date.now()) / 1000)
    );
    if (!seconds) {
        clearQR('二维码已过期');
        $('pair-status').textContent = '请重新生成二维码';
        return;
    }
    $('pair-status').textContent =
        `等待手机配对（${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')} 后过期）`;
};
const poll = async () => {
    if (!key || polling || document.hidden) return;
    polling = true;
    try {
        if (pairing && $('pair-dialog').open && !$('new-pair').disabled) {
            const current = pairing;
            const result = await api('/admin/api/pairing/status', 'POST', {
                pairing_token: current.pairing_token
            });
            if (current === pairing && result.status !== 'pending') {
                pairing = null;
                clearQR(
                    result.status === 'paired' ? '✓ 手机已配对' : '二维码已失效'
                );
                $('pair-status').textContent =
                    result.status === 'paired'
                        ? '可以关闭窗口，或生成二维码添加另一台手机。'
                        : '请重新生成二维码';
            }
        }
        await loadDevices();
        message('');
    } catch (error) {
        message(error.message);
    } finally {
        polling = false;
    }
};
$('login-form').onsubmit = async event => {
    event.preventDefault();
    const button = event.submitter;
    button.disabled = true;
    key = $('key').value.trim();
    try {
        const session = await api('/admin/api/session');
        await loadDevices();
        $('server-address').textContent = session.server_url;
        $('login').hidden = true;
        $('dashboard').hidden = $('logout').hidden = false;
        $('key').value = '';
        message('');
        timer = setInterval(poll, 5000);
    } catch (error) {
        key = '';
        message(error.message);
    } finally {
        button.disabled = false;
    }
};
$('logout').onclick = async () => {
    ++generation;
    clearInterval(timer);
    try {
        await cancelPairing();
    } catch {
        /* 未完成的配对码仍会在五分钟后过期 */
    }
    key = '';
    pairing = null;
    lastDevices = '';
    clearQR('');
    $('pair-dialog').close();
    $('edit-dialog').close();
    $('devices').replaceChildren();
    $('dashboard').hidden = $('logout').hidden = true;
    $('login').hidden = false;
    message('');
};
$('refresh').onclick = () => poll();
$('add').onclick = () => {
    $('pair-dialog').showModal();
    newPairing();
};
$('new-pair').onclick = newPairing;
$('close-pair').onclick = () => $('pair-dialog').close();
$('pair-dialog').addEventListener('close', async () => {
    ++generation;
    clearQR('');
    try {
        await cancelPairing();
    } catch (error) {
        message(error.message);
    }
});
setInterval(updateCountdown, 1000);
