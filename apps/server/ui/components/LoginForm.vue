<!-- ui/components/LoginForm.vue -->

<script setup lang="ts">
import { ref } from 'vue';
import { useRouter } from 'vue-router';
import { auth } from '../auth';
import { useAction } from '../composables/useAction';
import ErrorMessage from './ErrorMessage.vue';

// 管理员登录卡片表单, 校验并暂存管理员 API 访问凭据
const router = useRouter();
const key = ref('');
const remember = ref(true);
const { busy, error, run } = useAction();
const login = () =>
    run(async () => {
        await auth.login(key.value.trim(), remember.value);
        key.value = '';
        await router.replace({ name: 'dashboard' });
    });
</script>
<template>
    <section class="login">
        <div class="intro">
            <span class="eyebrow">
                <span class="eyebrow-dot" aria-hidden="true"></span>
                PHOTOS BRIDGE
            </span>
            <h1>让相册连接更多可能。</h1>
            <p>配对设备，管理相册，让我们为你搭起连接。</p>
            <div class="holo-bridge" aria-hidden="true">
                <svg class="bridge-svg" viewBox="0 0 420 120" fill="none">
                    <defs>
                        <linearGradient
                            id="bridge-line"
                            x1="0%"
                            y1="0%"
                            x2="100%"
                            y2="0%"
                        >
                            <stop
                                offset="0%"
                                stop-color="#007aff"
                                stop-opacity="0.15"
                            />
                            <stop
                                offset="50%"
                                stop-color="#00c6ff"
                                stop-opacity="0.95"
                            />
                            <stop
                                offset="100%"
                                stop-color="#35d6b5"
                                stop-opacity="0.2"
                            />
                        </linearGradient>
                        <linearGradient
                            id="bridge-glow"
                            x1="0%"
                            y1="0%"
                            x2="100%"
                            y2="0%"
                        >
                            <stop
                                offset="0%"
                                stop-color="#007aff"
                                stop-opacity="0.05"
                            />
                            <stop
                                offset="50%"
                                stop-color="#007aff"
                                stop-opacity="0.22"
                            />
                            <stop
                                offset="100%"
                                stop-color="#35d6b5"
                                stop-opacity="0.05"
                            />
                        </linearGradient>
                    </defs>
                    <path
                        d="M 56 86 Q 210 10 364 86"
                        stroke="url(#bridge-glow)"
                        stroke-width="10"
                        stroke-linecap="round"
                    />
                    <path
                        class="bridge-track"
                        d="M 56 86 Q 210 10 364 86"
                        stroke="url(#bridge-line)"
                        stroke-width="2"
                        stroke-dasharray="5 7"
                    />
                    <path
                        class="bridge-stream"
                        d="M 56 86 Q 210 10 364 86"
                        stroke="#007aff"
                        stroke-width="2.5"
                        stroke-linecap="round"
                        stroke-dasharray="28 180"
                    />
                    <path
                        class="bridge-stream-alt"
                        d="M 56 86 Q 210 34 364 86"
                        stroke="#35d6b5"
                        stroke-width="1.8"
                        stroke-linecap="round"
                        stroke-dasharray="18 160"
                    />
                    <g class="bridge-node node-left">
                        <circle
                            class="node-ripple"
                            cx="56"
                            cy="86"
                            r="18"
                            stroke="#007aff"
                            stroke-width="1.2"
                        />
                        <circle
                            cx="56"
                            cy="86"
                            r="12"
                            fill="#007aff"
                            fill-opacity="0.14"
                            stroke="#007aff"
                            stroke-width="1.5"
                        />
                        <circle cx="56" cy="86" r="4.5" fill="#007aff" />
                    </g>
                    <g class="bridge-node node-center">
                        <circle
                            class="node-ripple-delayed"
                            cx="210"
                            cy="48"
                            r="20"
                            stroke="#00c6ff"
                            stroke-width="1.2"
                        />
                        <circle
                            cx="210"
                            cy="48"
                            r="10"
                            fill="#00c6ff"
                            fill-opacity="0.18"
                            stroke="#007aff"
                            stroke-width="1.5"
                        />
                        <circle cx="210" cy="48" r="4" fill="#007aff" />
                    </g>
                    <g class="bridge-node node-right">
                        <circle
                            class="node-ripple"
                            cx="364"
                            cy="86"
                            r="18"
                            stroke="#35d6b5"
                            stroke-width="1.2"
                        />
                        <circle
                            cx="364"
                            cy="86"
                            r="12"
                            fill="#35d6b5"
                            fill-opacity="0.16"
                            stroke="#0e8da8"
                            stroke-width="1.5"
                        />
                        <circle cx="364" cy="86" r="4.5" fill="#0e8da8" />
                    </g>
                </svg>
                <div class="feature-chips">
                    <span class="chip">
                        <span class="chip-dot"></span>
                        高速通道
                    </span>
                    <span class="chip">
                        <span class="chip-dot"></span>
                        实时同步
                    </span>
                    <span class="chip">
                        <span class="chip-dot"></span>
                        安全鉴权
                    </span>
                </div>
            </div>
        </div>
        <form class="card login-card" @submit.prevent="login">
            <div class="card-hud-top" aria-hidden="true">
                <span class="hud-label">SECURITY GATEWAY // V1</span>
                <span class="hud-bars">
                    <i></i>
                    <i></i>
                    <i></i>
                </span>
            </div>
            <label for="key" class="login-title">管理密钥</label>
            <div class="input-shell">
                <input
                    id="key"
                    v-model="key"
                    type="password"
                    autocomplete="current-password"
                    placeholder="请输入管理密钥"
                    required
                />
                <span class="input-glow" aria-hidden="true"></span>
            </div>
            <label class="remember-row" for="remember-key">
                <input
                    id="remember-key"
                    v-model="remember"
                    type="checkbox"
                    class="remember-checkbox"
                />
                <span class="remember-box" aria-hidden="true">
                    <svg viewBox="0 0 12 10" fill="none">
                        <path
                            d="M1.5 5.2L4.6 8.2L10.5 1.8"
                            stroke="currentColor"
                            stroke-width="2"
                            stroke-linecap="round"
                            stroke-linejoin="round"
                        />
                    </svg>
                </span>
                <span class="remember-text">记住密钥</span>
            </label>
            <ErrorMessage :text="error" />
            <button type="submit" class="primary-cta" :disabled="busy">
                <span>{{ busy ? '正在登录...' : '登录' }}</span>
                <span class="btn-arrow" aria-hidden="true">→</span>
            </button>
        </form>
    </section>
</template>
