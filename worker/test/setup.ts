import { applyD1Migrations, env } from "cloudflare:test";

await applyD1Migrations(env.IDENTITY, env.TEST_MIGRATIONS);
