#!/usr/bin/env node
// copy-data.js — copy src/data into dist/data after a build.
//
// `npm run build` used to end in `rm -rf dist/data && cp -r src/data dist/data`,
// which npm runs through cmd.exe on Windows regardless of which shell started
// it — so the build failed there with "'rm' is not recognized". Node is already
// a hard dependency of this project, so doing it here keeps one command working
// on every platform.

import { cpSync, existsSync, rmSync } from "fs";
import { dirname, resolve } from "path";
import { fileURLToPath } from "url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const src = resolve(root, "src", "data");
const dest = resolve(root, "dist", "data");

if (!existsSync(src)) {
  console.error(`copy-data: ${src} does not exist`);
  process.exit(1);
}

// Recursive, force: the same thing `rm -rf` + `cp -r` did. Without the removal
// a file deleted from src would linger in dist and keep being read.
rmSync(dest, { recursive: true, force: true });
cpSync(src, dest, { recursive: true });
console.log(`copy-data: ${src} -> ${dest}`);
