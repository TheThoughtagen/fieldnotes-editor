import { defineConfig } from "vitest/config";
import { playwright } from "@vitest/browser-playwright";

export default defineConfig({
  test: {
    projects: [
      {
        test: {
          name: "node",
          environment: "node",
          exclude: ["test/**/*.browser.test.ts"]
        }
      },
      {
        optimizeDeps: { include: ["mermaid"] },
        test: {
          name: "browser",
          include: ["test/**/*.browser.test.ts"],
          browser: {
            enabled: true,
            headless: true,
            provider: playwright(),
            instances: [{ browser: "chromium" }]
          }
        }
      }
    ]
  }
});
