import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";

export default defineConfig({
  resolve: {
    alias: { "node:path": fileURLToPath(new URL("./src/browser-path.ts", import.meta.url)) },
  },
  root: ".",
  base: "./",
  build: {
    outDir: "../../build/editor-web",
    emptyOutDir: true,
    target: "safari17",
    chunkSizeWarningLimit: 800,
    rollupOptions: {
      external: [],
    },
  },
});
