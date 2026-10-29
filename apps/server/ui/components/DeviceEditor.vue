<!-- ui/components/DeviceEditor.vue -->

<script setup lang="ts">
import { computed, ref } from 'vue';
import type { AdminApi, Device } from '../api';
import { useAction } from '../composables/useAction';
import BaseDialog from './BaseDialog.vue';
import ErrorMessage from './ErrorMessage.vue';

// 设备修改与解绑弹窗, 根据传入的操作类型区分展示重命名或解绑确认表单
const props = defineProps<{
    api: AdminApi;
    device: Device;
    action: 'rename' | 'remove';
}>();
const emit = defineEmits<{ close: []; saved: [] }>();
const name = ref(props.device.display_name);
const rename = computed(() => props.action === 'rename');
const { busy, error, run } = useAction();
const save = () =>
    run(async () => {
        if (rename.value) {
            await props.api.rename(props.device, name.value);
        } else {
            await props.api.remove(props.device);
        }
        emit('saved');
        emit('close');
    });
</script>
<template>
    <BaseDialog
        :title="rename ? '重命名设备' : '解除配对'"
        :busy="busy"
        @close="emit('close')"
    >
        <form @submit.prevent="save">
            <p v-if="rename">设置一个便于区分的名称。</p>
            <p v-else>
                解除「{{
                    device.display_name
                }}」的配对后，这台设备将断开连接。再次使用需要重新扫码配对，不会删除设备照片。
            </p>
            <template v-if="rename"
                ><label for="device-name">设备名称</label
                ><input id="device-name" v-model="name" maxlength="80" required
            /></template>
            <ErrorMessage :text="error" />
            <div class="actions">
                <button
                    type="button"
                    class="secondary"
                    :disabled="busy"
                    @click="emit('close')"
                >
                    取消</button
                ><button
                    type="submit"
                    :class="{ danger: !rename }"
                    :disabled="busy || (rename && !name.trim())"
                >
                    {{ rename ? '保存' : '解除配对' }}
                </button>
            </div>
        </form>
    </BaseDialog>
</template>
