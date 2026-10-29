// ui/composables/useInterval.ts

import { onMounted, onUnmounted } from 'vue';

/**
 * 定时周期性轮询组合式函数
 * 随组件挂载启动定时器, 并在组件卸载时自动清理, 防止内存泄漏
 */
export const useInterval = (callback: () => void, milliseconds: number) => {
    let timer: ReturnType<typeof setInterval>;
    onMounted(() => {
        timer = setInterval(callback, milliseconds);
    });
    onUnmounted(() => clearInterval(timer));
};
