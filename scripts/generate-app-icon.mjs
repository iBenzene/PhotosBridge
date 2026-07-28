import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { deflateSync } from "node:zlib";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const source = join(repositoryRoot, "design/photos-bridge.svg");
const destination = join(repositoryRoot, "apps/apple/PhotosBridge/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png");
const workingDirectory = mkdtempSync(join(tmpdir(), "photos-bridge-app-icon-"));
const bitmap = join(workingDirectory, "AppIcon-1024.bmp");

const runSips = (args, captureOutput = false) => {
    const result = spawnSync("/usr/bin/sips", args, {
        encoding: "utf8",
        stdio: captureOutput ? "pipe" : "inherit",
    });

    if (result.error) {
        throw result.error;
    }

    if (result.status !== 0) {
        throw new Error(result.stderr || `sips exited with status ${result.status}`);
    }

    return result.stdout ?? "";
};

const crcTable = Array.from({ length: 256 }, (_, value) => {
    let crc = value;

    for (let bit = 0; bit < 8; bit += 1) {
        crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
    }

    return crc >>> 0;
});

const pngChunk = (type, data) => {
    const typeBuffer = Buffer.from(type, "ascii");
    const length = Buffer.alloc(4);
    length.writeUInt32BE(data.length);

    let crc = 0xffffffff;
    for (const byte of Buffer.concat([typeBuffer, data])) {
        crc = crcTable[(crc ^ byte) & 0xff] ^ (crc >>> 8);
    }

    const checksum = Buffer.alloc(4);
    checksum.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
    return Buffer.concat([length, typeBuffer, data, checksum]);
};

const convertBitmapToOpaquePng = (bitmapPath, pngPath) => {
    const bmp = readFileSync(bitmapPath);
    const pixelOffset = bmp.readUInt32LE(10);
    const width = bmp.readInt32LE(18);
    const signedHeight = bmp.readInt32LE(22);
    const height = Math.abs(signedHeight);
    const bitsPerPixel = bmp.readUInt16LE(28);
    const compression = bmp.readUInt32LE(30);
    const usesStandardBgraMasks =
        bitsPerPixel === 32 &&
        compression === 3 &&
        bmp.readUInt32LE(54) === 0x00ff0000 &&
        bmp.readUInt32LE(58) === 0x0000ff00 &&
        bmp.readUInt32LE(62) === 0x000000ff;

    if (
        width <= 0 ||
        height <= 0 ||
        ![24, 32].includes(bitsPerPixel) ||
        (compression !== 0 && !usesStandardBgraMasks)
    ) {
        throw new Error("sips produced an unsupported BMP format.");
    }

    const bytesPerPixel = bitsPerPixel / 8;
    const sourceRowBytes = Math.ceil((width * bitsPerPixel) / 32) * 4;
    const scanlines = Buffer.alloc((width * 3 + 1) * height);

    for (let y = 0; y < height; y += 1) {
        const sourceY = signedHeight > 0 ? height - 1 - y : y;
        const sourceRow = pixelOffset + sourceY * sourceRowBytes;
        const destinationRow = y * (width * 3 + 1);

        scanlines[destinationRow] = 0;
        for (let x = 0; x < width; x += 1) {
            const sourcePixel = sourceRow + x * bytesPerPixel;
            const destinationPixel = destinationRow + 1 + x * 3;
            scanlines[destinationPixel] = bmp[sourcePixel + 2];
            scanlines[destinationPixel + 1] = bmp[sourcePixel + 1];
            scanlines[destinationPixel + 2] = bmp[sourcePixel];
        }
    }

    const header = Buffer.alloc(13);
    header.writeUInt32BE(width, 0);
    header.writeUInt32BE(height, 4);
    header[8] = 8;
    header[9] = 2;

    writeFileSync(
        pngPath,
        Buffer.concat([
            Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
            pngChunk("IHDR", header),
            pngChunk("IDAT", deflateSync(scanlines, { level: 9 })),
            pngChunk("IEND", Buffer.alloc(0)),
        ])
    );
};

try {
    mkdirSync(dirname(destination), { recursive: true });

    // App Store icons must be RGB-only. The BMP intermediate is decoded into a
    // PNG color type 2 file, which cannot contain an alpha channel.
    runSips(["-s", "format", "bmp", source, "--out", bitmap]);
    convertBitmapToOpaquePng(bitmap, destination);

    const metadata = runSips(["-g", "pixelWidth", "-g", "pixelHeight", "-g", "hasAlpha", destination], true);

    if (!metadata.includes("pixelWidth: 1024") || !metadata.includes("pixelHeight: 1024")) {
        throw new Error(`Generated icon has unexpected dimensions:\n${metadata}`);
    }

    if (metadata.includes("hasAlpha: yes")) {
        throw new Error("Generated icon unexpectedly contains an alpha channel.");
    }

    console.log(`Generated ${destination}`);
} finally {
    rmSync(workingDirectory, { force: true, recursive: true });
}
