// ui/main.ts

import { createApp } from 'vue';
import App from './App.vue';
import { router } from './router';
import './styles.less';

// 初始化 Web 控制台应用实例并挂载至页面根容器。
createApp(App).use(router).mount('#app');
