// vite.config.ts

import { fileURLToPath } from 'node:url';
import vue from '@vitejs/plugin-vue';
import { defineConfig } from 'vite';

// Web 控制台前端打包配置, 产物输出至「dist/ui」目录
export default defineConfig({
    base: '/ui/',
    build: { emptyOutDir: true, outDir: '../dist/ui' },
    plugins: [vue()],
    publicDir: false,
    resolve: {
        alias: { '/src': fileURLToPath(new URL('./ui', import.meta.url)) }
    },
    root: fileURLToPath(new URL('./public', import.meta.url)),
    // 本地开发模式下将 API 请求反向代理至后端服务端口
    server: {
        proxy: {
            '/api': 'http://127.0.0.1:8787',
            '/ui/api': 'http://127.0.0.1:8787'
        }
    }
});
