<!-- ui/components/DeviceDashboard.vue -->

<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref } from 'vue';
import type { AdminApi, Device } from '../api';
import { useAction } from '../composables/useAction';
import { useInterval } from '../composables/useInterval';
import DeviceCard from './DeviceCard.vue';
import DeviceEditor from './DeviceEditor.vue';
import PairingDialog from './PairingDialog.vue';
import ErrorMessage from './ErrorMessage.vue';

// 设备管理主控制台, 定期轮询设备状态并在标签页处于后台时自动静默挂起
const props = defineProps<{ api: AdminApi; serverUrl: string }>();
const devices = ref<Device[]>([]);
const loaded = ref(false);
const pairingOpen = ref(false);
const edit = ref<{ device: Device; action: 'rename' | 'remove' }>();
const { busy, error, run } = useAction();
let disposed = false;
const refresh = () =>
    run(async () => {
        const result = await props.api.devices();
        if (!disposed) {
            devices.value = result.devices;
            loaded.value = true;
        }
    });
// 页面处于前台可见状态时每 5 秒轮询刷新一次设备列表
useInterval(() => {
    if (!document.hidden) {
        void refresh();
    }
}, 5000);
onMounted(refresh);
onBeforeUnmount(() => {
    disposed = true;
});
</script>
<template>
    <section class="dashboard">
        <div class="heading">
            <div class="heading-main">
                <h1>我的设备</h1>
                <p class="server-pill">
                    <span class="server-pulse" aria-hidden="true"></span>
                    <span class="server-label" aria-hidden="true"
                        >ENDPOINT</span
                    >
                    <span class="server-url">{{ serverUrl }}</span>
                </p>
            </div>
            <button
                class="primary-cta add-device-btn"
                @click="pairingOpen = true"
            >
                <span>＋ 添加设备</span>
            </button>
        </div>
        <ErrorMessage :text="error" />
        <div class="section-title">
            <h2>
                <span class="section-indicator" aria-hidden="true"></span>
                已配对{{ loaded ? `（${devices.length}）` : '' }}
            </h2>
            <button
                class="quiet refresh-btn"
                :class="{ spinning: busy }"
                :disabled="busy"
                @click="refresh"
            >
                <svg
                    class="refresh-icon"
                    viewBox="0 0 16 16"
                    fill="none"
                    aria-hidden="true"
                >
                    <path
                        d="M13.65 2.35A7.95 7.95 0 0 0 8 0a8 8 0 1 0 7.73 10h-2.08A6 6 0 1 1 8 2c1.66 0 3.14.69 4.22 1.78L9 7h7V0l-2.35 2.35Z"
                        fill="currentColor"
                    />
                </svg>
                刷新
            </button>
        </div>
        <div class="card device-deck">
            <TransitionGroup name="device-list" tag="div" class="device-items">
                <DeviceCard
                    v-for="device in devices"
                    :key="device.device_id"
                    :device="device"
                    @edit="action => (edit = { device, action })"
                />
            </TransitionGroup>
            <div v-if="!devices.length" class="empty">
                <div class="empty-radar" aria-hidden="true">
                    <span class="radar-ring ring-1"></span>
                    <span class="radar-ring ring-2"></span>
                    <span class="radar-sweep"></span>
                    <svg class="radar-core" viewBox="0 0 36 32" fill="none">
                        <path
                            d="M19 25H6.5A2.5 2.5 0 0 1 4 22.5v-17A2.5 2.5 0 0 1 6.5 3h14A2.5 2.5 0 0 1 23 5.5V9"
                            stroke="currentColor"
                            stroke-width="1.8"
                            stroke-linecap="round"
                        />
                        <circle cx="13.5" cy="6" r="1" fill="currentColor" />
                        <rect
                            x="20"
                            y="11"
                            width="12"
                            height="18"
                            rx="2.5"
                            stroke="currentColor"
                            stroke-width="1.8"
                        />
                        <line
                            x1="24.5"
                            y1="13.8"
                            x2="27.5"
                            y2="13.8"
                            stroke="currentColor"
                            stroke-width="1.5"
                            stroke-linecap="round"
                        />
                        <circle cx="26" cy="26" r="1" fill="currentColor" />
                    </svg>
                </div>
                <h2>{{ !loaded ? '正在加载设备...' : '还没有配对的设备' }}</h2>
                <p v-if="loaded">点击「添加设备」，扫描二维码即可连接。</p>
            </div>
        </div>
        <p class="hint">
            已配对设备会自动连接。如果未能连接，请先在设备上打开「照片桥」。
        </p>
        <PairingDialog
            v-if="pairingOpen"
            :api="api"
            @close="pairingOpen = false"
            @paired="refresh"
        />
        <DeviceEditor
            v-if="edit"
            :api="api"
            :device="edit.device"
            :action="edit.action"
            @close="edit = undefined"
            @saved="refresh"
        />
    </section>
</template>
