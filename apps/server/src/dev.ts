// src/dev.ts

import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { prepareEnvironment } from './auto-config.js';

const startDevelopmentServer = async (): Promise<void> => {
    // 「tsx watch」依赖标准输入捕获快捷键以触发重启。
    // 在子进程启动前完成所有的交互式配置提示, 避免主子进程竞争标准输入。
    await prepareEnvironment();

    const tsxCli = fileURLToPath(import.meta.resolve('tsx/cli'));
    const child = spawn(process.execPath, [tsxCli, 'watch', 'src/index.ts'], {
        cwd: fileURLToPath(new URL('..', import.meta.url)),
        env: process.env,
        stdio: 'inherit'
    });

    child.once('error', error => {
        console.error('Failed to start development server:', error);
        process.exitCode = 1;
    });

    child.once('exit', (code, signal) => {
        if (signal) {
            process.kill(process.pid, signal);
            return;
        }
        process.exitCode = code ?? 1;
    });
};

startDevelopmentServer().catch(error => {
    console.error('Failed to start development server:', error);
    process.exit(1);
});
