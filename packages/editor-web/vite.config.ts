import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";

export default defineConfig({
  resolve: {
    alias: { "node:path": fileURLToPath(new URL("./src/browser-path.ts", import.meta.url)) },
  },
  // WKWebView file URLs reject module CORS requests. Emit one classic deferred
  // bundle rather than weakening file access or CSP.
  plugins: [{ name: "wk-file-script", transformIndexHtml: { order: "post", handler: html => html.replace(/type="module" crossorigin/g, "defer").replace(/ rel="stylesheet" crossorigin/g, ' rel="stylesheet"') } }],
  root: ".",
  base: "./",
  build: {
    outDir: "../../build/editor-web",
    emptyOutDir: true,
    target: "safari17",
    chunkSizeWarningLimit: 8000,
    rollupOptions: {
      external: [],
      output: { format: "iife", codeSplitting: false },
    },
  },
});
