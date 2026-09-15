import { defineConfig } from "vite";

export default defineConfig({
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
