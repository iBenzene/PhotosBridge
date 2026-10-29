<!-- ui/components/PairingDialog.vue -->

<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue';
import type { AdminApi, Pairing, PairingStatus } from '../api';
import { useAction } from '../composables/useAction';
import { useInterval } from '../composables/useInterval';
import BaseDialog from './BaseDialog.vue';
import ErrorMessage from './ErrorMessage.vue';

// 设备扫码配对弹窗, 负责二维码渲染、倒计时管理以及配对成功状态的轮询检测
const props = defineProps<{ api: AdminApi }>();
const emit = defineEmits<{ close: []; paired: [] }>();
const { busy, error, run } = useAction();
const pairing = ref<Pairing>();
const status = ref<PairingStatus>('pending');
const now = ref(Date.now());
let disposed = false;
let polling = false;
const seconds = computed(
    () =>
        Math.max(
            0,
            Math.ceil(
                (Date.parse(pairing.value?.expires_at ?? '') - now.value) / 1000
            )
        ) || 0
);
const visibleQR = computed(
    () =>
        !busy.value &&
        status.value === 'pending' &&
        seconds.value > 0 &&
        pairing.value
);
const statusText = computed(() => {
    if (busy.value) {
        return '正在生成二维码...';
    }
    if (status.value === 'paired') {
        return '可以关闭窗口，或生成二维码添加另一台设备。';
    }
    if (!pairing.value) {
        return '点击重新生成二维码以重试。';
    }
    if (!seconds.value || status.value !== 'pending') {
        return '二维码已失效，请重新生成。';
    }
    return `等待设备配对（${Math.floor(seconds.value / 60)}:${String(seconds.value % 60).padStart(2, '0')} 后过期）`;
});
const cancel = async () => {
    const current = pairing.value;
    if (current) {
        await props.api.cancelPairing(current);
        if (current === pairing.value) {
            pairing.value = undefined;
        }
    }
};
const generate = () =>
    run(async () => {
        await cancel();
        status.value = 'pending';
        const created = await props.api.createPairing();
        if (disposed) {
            await props.api.cancelPairing(created);
            return;
        }
        pairing.value = created;
        now.value = Date.now();
    });
const close = () =>
    run(async () => {
        await cancel();
        emit('close');
    });
const poll = async () => {
    const current = pairing.value;
    if (
        !current ||
        busy.value ||
        polling ||
        document.hidden ||
        status.value !== 'pending'
    ) {
        return;
    }
    polling = true;
    try {
        const result = await props.api.pairingStatus(current);
        if (disposed || current !== pairing.value) {
            return;
        }
        status.value = result.status;
        error.value = '';
        if (result.status === 'paired') {
            emit('paired');
        }
    } catch (cause) {
        error.value =
            cause instanceof Error
                ? cause.message
                : '无法获取配对状态，请重试。';
    } finally {
        polling = false;
    }
};
useInterval(() => {
    now.value = Date.now();
}, 1000);
// 定期轮询检查当前配对令牌是否已被手机端扫码核销
useInterval(() => {
    void poll();
}, 3000);
onMounted(generate);
onBeforeUnmount(() => {
    disposed = true;
    // 页面退出时尽力撤销未使用的配对码, 网络不可用时由五分钟有效期兜底
    void cancel().catch(() => undefined);
});
</script>
<template>
    <BaseDialog title="添加设备" :busy="busy" @close="close">
        <p>在照片桥 App 中打开「配对服务器」，扫描下方二维码，再确认配对。</p>
        <div
            class="qr-space"
            :class="{
                'is-paired': status === 'paired',
                'is-scanning': Boolean(visibleQR)
            }"
        >
            <span class="qr-corner corner-tl" aria-hidden="true"></span>
            <span class="qr-corner corner-tr" aria-hidden="true"></span>
            <span class="qr-corner corner-bl" aria-hidden="true"></span>
            <span class="qr-corner corner-br" aria-hidden="true"></span>
            <template v-if="visibleQR">
                <div class="qr-frame">
                    <img
                        :src="visibleQR.qr"
                        alt="设备配对二维码"
                        width="280"
                        height="280"
                    />
                    <span class="qr-laser" aria-hidden="true"></span>
                </div>
            </template>
            <div v-else class="qr-placeholder">
                <span
                    v-if="busy"
                    class="holo-spinner"
                    aria-hidden="true"
                ></span>
                <p>
                    {{
                        status === 'paired'
                            ? '🎉 设备已配对'
                            : busy
                              ? '正在生成二维码...'
                              : '暂无可用二维码'
                    }}
                </p>
            </div>
        </div>
        <p class="pair-status" role="status">{{ statusText }}</p>
        <ErrorMessage :text="error" />
        <p class="hint">每个二维码仅限一台设备使用。</p>
        <button class="wide primary-cta" :disabled="busy" @click="generate">
            <span>重新生成二维码</span>
        </button>
    </BaseDialog>
</template>
