import { playwright } from "@vitest/browser-playwright";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: { alias: { "node:path": fileURLToPath(new URL("./src/browser-path.ts", import.meta.url)) } },
  optimizeDeps: {
    include: [
      "@codemirror/autocomplete",
      "@codemirror/commands",
      "@codemirror/lang-markdown",
      "@codemirror/language",
      "@codemirror/lint",
      "@codemirror/search",
      "@codemirror/state",
      "@codemirror/view",
      "@replit/codemirror-vim",
    ],
  },
  test: {
    include: ["test/**/*.test.ts"],
    browser: {
      enabled: true,
      headless: true,
      provider: playwright(),
      instances: [{ browser: "chromium" }],
    },
  },
});
