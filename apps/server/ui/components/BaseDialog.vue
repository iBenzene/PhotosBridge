<!-- ui/components/BaseDialog.vue -->

<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref } from 'vue';

// 原生 HTMLDialogElement 模态弹窗封装, 挂载时自动调用「showModal」打开
withDefaults(defineProps<{ title: string; busy?: boolean }>(), { busy: false });
const emit = defineEmits<{ close: [] }>();
const dialog = ref<HTMLDialogElement>();
onMounted(() => dialog.value?.showModal());
onBeforeUnmount(() => dialog.value?.close());
</script>

<template>
    <dialog
        ref="dialog"
        :aria-label="title"
        @cancel.prevent="!busy && emit('close')"
    >
        <div class="dialog-heading">
            <h2>{{ title }}</h2>
            <button
                type="button"
                class="quiet"
                :disabled="busy"
                @click="emit('close')"
            >
                关闭
            </button>
        </div>
        <slot />
    </dialog>
</template>
