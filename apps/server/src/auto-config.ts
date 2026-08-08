/**
 * @file auto-config.ts
 * @description Development-time environment auto-configuration shared by direct and watch-mode startup.
 * @author iBenzene
 */
import crypto from "node:crypto";
import os from "node:os";
import readline from "node:readline/promises";

const getLocalIPv4Addresses = (): string[] => {
    const interfaces = os.networkInterfaces();
    const ips: string[] = [];
    for (const name of Object.keys(interfaces)) {
        for (const iface of interfaces[name] ?? []) {
            if (iface.family === "IPv4" && !iface.internal) {
                ips.push(iface.address);
            }
        }
    }
    return ips;
};

export const prepareEnvironment = async (): Promise<void> => {
    const isProduction = process.env.NODE_ENV === "production";

    // Auto-generate the admin key once in the parent process so it remains
    // stable when the development file watcher restarts the server process.
    if (!process.env.PHOTOS_BRIDGE_ADMIN_KEY) {
        const autoKey = crypto.randomBytes(16).toString("hex");
        process.env.PHOTOS_BRIDGE_ADMIN_KEY = autoKey;
        console.log(`💡 [Auto-Config] Generated random PHOTOS_BRIDGE_ADMIN_KEY: ${autoKey}`);
    }

    if (process.env.PUBLIC_BASE_URL) return;

    if (isProduction) {
        throw new Error("Fatal Error: PUBLIC_BASE_URL environment variable is mandatory in production mode.");
    }

    const port = Number(process.env.PORT ?? 8787);
    const localIPs = getLocalIPv4Addresses();
    const availableIPs = [...localIPs, "127.0.0.1"];
    let selectedIP = availableIPs[0];

    if (process.stdin.isTTY && availableIPs.length > 1) {
        console.log("\n🔍 PUBLIC_BASE_URL is unset. Available local IP addresses:");
        availableIPs.forEach((ip, index) => {
            const hint =
                index === 0
                    ? " (Recommended for physical devices)"
                    : ip === "127.0.0.1"
                      ? " (Localhost/Simulator only)"
                      : "";
            console.log(`  [${index + 1}] http://${ip}:${port}${hint}`);
        });

        const rl = readline.createInterface({
            input: process.stdin,
            output: process.stdout,
        });

        try {
            const answer = await rl.question(`\nSelect IP number for pairing [default 1: ${selectedIP}]: `);
            const choice = Number.parseInt(answer.trim(), 10);
            if (!Number.isNaN(choice) && choice >= 1 && choice <= availableIPs.length) {
                selectedIP = availableIPs[choice - 1];
            }
        } catch {
            // Use the recommended address when interactive input is interrupted.
        } finally {
            rl.close();
        }
    }

    process.env.PUBLIC_BASE_URL = `http://${selectedIP}:${port}`;
    console.log(`💡 [Auto-Config] Set PUBLIC_BASE_URL to: ${process.env.PUBLIC_BASE_URL}`);
};
