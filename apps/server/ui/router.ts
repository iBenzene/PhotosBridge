// ui/router.ts

import { createRouter, createWebHistory } from 'vue-router';
import { auth } from './auth';
import LoginForm from './components/LoginForm.vue';
import DeviceDashboard from './components/DeviceDashboard.vue';

export const router = createRouter({
    history: createWebHistory('/ui/'),
    routes: [
        {
            component: DeviceDashboard,
            meta: { requiresAuth: true },
            name: 'dashboard',
            path: '/',
            props: () => ({ api: auth.api, serverUrl: auth.state.serverUrl })
        },
        { component: LoginForm, name: 'login', path: '/login' },
        { path: '/:pathMatch(.*)*', redirect: '/' }
    ]
});

// 全局前置路由守卫, 校验会话状态并在未登录时重定向至登录页。
router.beforeEach(async to => {
    await auth.restore();
    if (to.meta.requiresAuth && auth.state.status === 'anonymous') {
        return { name: 'login', replace: true };
    }
    if (to.name === 'login' && auth.state.status === 'authenticated') {
        return { name: 'dashboard', replace: true };
    }
});
