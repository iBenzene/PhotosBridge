<!-- ui/components/DeviceCard.vue -->

<script setup lang="ts">
import type { Device } from '../api';

// 渲染单台已配对设备卡片, 展示实时连接状态与操作入口
defineProps<{ device: Device }>();
defineEmits<{ edit: [action: 'rename' | 'remove'] }>();
const readableDate = (value: string | null) =>
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
</script>
<template>
    <article class="device" :class="{ 'is-online': device.online }">
        <span
            class="phone"
            :class="{ 'phone-online': device.online }"
            aria-hidden="true"
        >
            <span class="phone-halo"></span>
            <svg class="phone-svg" viewBox="0 0 46 44" fill="none">
                <!-- 平板轮廓与全息核心 (左后方) -->
                <path
                    d="M22.5 37H7.5A4.5 4.5 0 0 1 3 32.5v-23A4.5 4.5 0 0 1 7.5 5h17A4.5 4.5 0 0 1 29 9.5V12"
                    stroke="currentColor"
                    stroke-width="2"
                    stroke-linecap="round"
                />
                <circle
                    cx="16"
                    cy="8.5"
                    r="1.1"
                    fill="currentColor"
                    fill-opacity="0.65"
                />
                <circle
                    class="phone-core-ring"
                    cx="15.5"
                    cy="21"
                    r="5.2"
                    stroke="currentColor"
                    stroke-width="1.2"
                    stroke-dasharray="2.8 2.4"
                />
                <circle
                    class="phone-core-dot"
                    cx="15.5"
                    cy="21"
                    r="1.9"
                    fill="currentColor"
                />
                <line
                    x1="11.5"
                    y1="33.5"
                    x2="18.5"
                    y2="33.5"
                    stroke="currentColor"
                    stroke-width="1.6"
                    stroke-linecap="round"
                    stroke-opacity="0.55"
                />
                <!-- 手机轮廓与全息核心 (右前方) -->
                <rect
                    x="25"
                    y="14"
                    width="18"
                    height="26"
                    rx="4"
                    stroke="currentColor"
                    stroke-width="2"
                />
                <rect
                    x="31"
                    y="17"
                    width="6"
                    height="1.8"
                    rx="0.9"
                    fill="currentColor"
                    fill-opacity="0.6"
                />
                <circle
                    class="phone-core-ring-sub"
                    cx="34"
                    cy="27"
                    r="3.8"
                    stroke="currentColor"
                    stroke-width="1.15"
                    stroke-dasharray="2.2 2"
                />
                <circle
                    class="phone-core-dot"
                    cx="34"
                    cy="27"
                    r="1.6"
                    fill="currentColor"
                />
                <line
                    x1="30.5"
                    y1="36.8"
                    x2="37.5"
                    y2="36.8"
                    stroke="currentColor"
                    stroke-width="1.5"
                    stroke-linecap="round"
                    stroke-opacity="0.6"
                />
            </svg>
        </span>
        <div class="device-info">
            <h3>
                <span class="device-name">{{ device.display_name }}</span>
                <span class="badge" :class="{ online: device.online }">{{
                    device.online ? '● 在线' : '○ 离线'
                }}</span>
            </h3>
            <p class="device-id-line">{{ device.device_id }}</p>
            <p class="device-meta-line">
                最近连接：{{ readableDate(device.last_seen_at) }} / App
                {{ device.app_version }}
            </p>
        </div>
        <div class="actions">
            <button class="quiet action-btn" @click="$emit('edit', 'rename')">
                重命名
            </button>
            <button class="danger action-btn" @click="$emit('edit', 'remove')">
                解除配对
            </button>
        </div>
    </article>
</template>
