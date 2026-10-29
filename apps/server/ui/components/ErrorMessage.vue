<!-- ui/components/ErrorMessage.vue -->

<script setup lang="ts">
// 呈现表单或操作执行错误消息, 仅在存在文本内容时渲染
defineProps<{ text: string }>();
</script>
<template>
    <p v-if="text" class="error" role="alert">{{ text }}</p>
</template>
