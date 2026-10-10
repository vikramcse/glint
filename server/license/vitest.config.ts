import { readFileSync } from "node:fs";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig(async () => {
  const migrations = await readD1Migrations("./migrations");
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: migrations,
            // Published TEST key (see test/fixtures/test-private.key); never a production key.
            LICENSE_PRIVATE_KEY: readFileSync("./test/fixtures/test-private.key", "utf8").trim(),
            LEMONSQUEEZY_WEBHOOK_SECRET: "test-webhook-secret",
            TOKEN_FIXTURE: readFileSync("./test/fixtures/tokens.json", "utf8"),
          },
        },
      }),
    ],
    test: { setupFiles: ["./test/apply-migrations.ts"] },
  };
});
