import { readFileSync } from "fs"
import { dirname, join } from "path"
import { fileURLToPath } from "url"

declare global {
  const OPENCODE_VERSION: string
  const OPENCODE_CHANNEL: string
}

// When built with `bun run build`, OPENCODE_VERSION/CHANNEL are compile-time
// defines and this file resolves to them directly. When running from source
// (bun run ./src/index.ts), the defines are absent and we fall back to the
// version baked into the workspace package.json so tools that parse
// `opencode --version` (e.g. editor integrations doing a health check) see a
// real semver instead of the opaque "local" string.
function packageVersion(): string {
  // from src/installation/ -> package root is two levels up
  const pkgPath = join(dirname(fileURLToPath(import.meta.url)), "../../package.json")
  try {
    const parsed = JSON.parse(readFileSync(pkgPath, "utf8")) as { version?: string }
    if (typeof parsed.version === "string" && /^\d+\.\d+\.\d+/.test(parsed.version)) return parsed.version
  } catch {
    // fall through to the legacy "local" marker
  }
  return "local"
}

export const InstallationVersion = typeof OPENCODE_VERSION === "string" ? OPENCODE_VERSION : packageVersion()
export const InstallationChannel = typeof OPENCODE_CHANNEL === "string" ? OPENCODE_CHANNEL : "local"
export const InstallationLocal = InstallationChannel === "local"
