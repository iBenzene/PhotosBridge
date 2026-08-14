/**
 * @file dev.ts
 * @description Interactive development launcher that configures the environment before starting tsx watch.
 * @author iBenzene
 */
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { prepareEnvironment } from "./auto-config.js";

const startDevelopmentServer = async (): Promise<void> => {
    // tsx watch uses stdin for its own restart shortcut. Complete all prompts
    // before it starts so both processes never compete for the same input.
    await prepareEnvironment();

    const tsxCli = fileURLToPath(import.meta.resolve("tsx/cli"));
    const child = spawn(process.execPath, [tsxCli, "watch", "src/index.ts"], {
        cwd: fileURLToPath(new URL("..", import.meta.url)),
        env: process.env,
        stdio: "inherit",
    });

    child.once("error", error => {
        console.error("Failed to start development server:", error);
        process.exitCode = 1;
    });

    child.once("exit", (code, signal) => {
        if (signal) {
            process.kill(process.pid, signal);
            return;
        }
        process.exitCode = code ?? 1;
    });
};

startDevelopmentServer().catch(error => {
    console.error("Failed to start development server:", error);
    process.exit(1);
});
