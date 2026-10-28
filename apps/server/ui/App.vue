<!-- ui/App.vue -->

<script setup lang="ts">
import { onBeforeUnmount, watch } from 'vue';
import { RouterLink, RouterView } from 'vue-router';
import logo from '../public/logo.svg';
import { auth } from './auth';
import { router } from './router';
import { useAction } from './composables/useAction';
import ErrorMessage from './components/ErrorMessage.vue';

const { busy, error, run } = useAction();
const channel =
    typeof BroadcastChannel === 'undefined'
        ? undefined
        : new BroadcastChannel('photos-bridge-auth');
if (channel) {
    channel.onmessage = event => {
        if (event.data === 'logout') {
            auth.invalidate();
        }
    };
}
onBeforeUnmount(() => channel?.close());
watch(
    () => auth.state.status,
    status => {
        if (status === 'anonymous') {
            void router.replace({ name: 'login' });
        }
    }
);
const logout = () =>
    run(async () => {
        await auth.logout();
        channel?.postMessage('logout');
        await router.replace({ name: 'login' });
    });
const retry = async () => {
    await auth.restore();
    if (auth.state.status !== 'unknown') {
        await router.replace({
            name: auth.state.status === 'authenticated' ? 'dashboard' : 'login'
        });
    }
};
</script>
<template>
    <div class="ambient-bg" aria-hidden="true">
        <div class="ambient-grid"></div>
        <div class="ambient-scan"></div>
        <div class="ambient-orb orb-primary"></div>
        <div class="ambient-orb orb-secondary"></div>
        <svg class="ambient-rings" viewBox="0 0 800 800" fill="none">
            <circle
                class="ring-outer"
                cx="400"
                cy="400"
                r="340"
                stroke="currentColor"
                stroke-width="1"
                stroke-dasharray="6 14 28 14"
            />
            <circle
                class="ring-middle"
                cx="400"
                cy="400"
                r="260"
                stroke="currentColor"
                stroke-width="1.2"
                stroke-dasharray="80 40 12 40"
            />
            <circle
                class="ring-inner"
                cx="400"
                cy="400"
                r="180"
                stroke="currentColor"
                stroke-width="1"
                stroke-dasharray="4 10"
            />
        </svg>
    </div>
    <header>
        <RouterLink to="/" class="brand">
            <span class="logo-wrap">
                <img class="logo" :src="logo" alt="照片桥 Logo" />
                <span class="logo-glow" aria-hidden="true"></span>
            </span>
            <span class="brand-text">照片桥</span>
            <span class="tag">
                <span class="tag-dot" aria-hidden="true"></span>
                管理
            </span>
        </RouterLink>
        <div v-if="auth.state.status === 'authenticated'" class="header-right">
            <span class="sys-pill" aria-hidden="true">
                <span class="sys-dot"></span>
                LINK ACTIVE
            </span>
            <button class="quiet logout-btn" :disabled="busy" @click="logout">
                退出登录
            </button>
        </div>
    </header>
    <main>
        <ErrorMessage :text="error" />
        <section
            v-if="auth.state.status === 'unknown'"
            class="card status-card"
            aria-live="polite"
        >
            <template v-if="auth.state.error">
                <ErrorMessage :text="auth.state.error" />
                <button :disabled="auth.state.loading" @click="retry">
                    重试
                </button>
            </template>
            <div v-else class="loading-state">
                <span class="holo-spinner" aria-hidden="true"></span>
                <p>正在恢复登录状态...</p>
            </div>
        </section>
        <RouterView v-else v-slot="{ Component, route }">
            <Transition name="view" mode="out-in">
                <component
                    :is="Component"
                    :key="String(route.name ?? route.path)"
                />
            </Transition>
        </RouterView>
    </main>
</template>
