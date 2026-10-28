// ui/composables/useAction.ts

import { ref } from 'vue';

/**
 * 异步操作执行状态管理组合式函数。
 * 跟踪繁忙中状态「busy」以防重复点击, 并捕获异常错误消息「error」。
 */
export const useAction = () => {
    const busy = ref(false);
    const error = ref('');
    const run = async (work: () => Promise<void>) => {
        if (busy.value) {
            return;
        }
        busy.value = true;
        error.value = '';
        try {
            await work();
        } catch (cause) {
            error.value =
                cause instanceof Error ? cause.message : '操作失败，请重试。';
        } finally {
            busy.value = false;
        }
    };
    return { busy, error, run };
};
