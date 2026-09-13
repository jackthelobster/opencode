import { describe, expect, test } from "bun:test"
import fs from "fs"
import os from "os"
import path from "path"
import type { Provider } from "../../src/provider/provider"
import { SystemPrompt } from "../../src/session/system"

// The SYSTEM.md override lives in the user's home, so point HOME at a scratch
// dir per test to keep the filesystem isolation airtight.
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "system-override-"))

function withHome(home: string, fn: () => void) {
  const previous = process.env.OPENCODE_TEST_HOME
  process.env.OPENCODE_TEST_HOME = home
  try {
    fn()
  } finally {
    if (previous === undefined) delete process.env.OPENCODE_TEST_HOME
    else process.env.OPENCODE_TEST_HOME = previous
  }
}

const model = { api: { id: "claude-sonnet-4" } } as Provider.Model

describe("session.system custom prompt", () => {
  test("no SYSTEM.md anywhere -> bundled prompts still used", () => {
    withHome(scratch, () => {
      const prompt = SystemPrompt.provider(model)[0]
      expect(prompt).not.toContain("CUSTOM SYSTEM MARKER")
    })
  })

  test("SYSTEM.md in ~/.opencode completely replaces the bundled prompt", () => {
    const home = path.join(scratch, "dot-opencode")
    fs.mkdirSync(path.join(home, ".opencode"), { recursive: true })
    fs.writeFileSync(
      path.join(home, ".opencode", "SYSTEM.md"),
      "You are a custom agent. CUSTOM SYSTEM MARKER",
    )
    withHome(home, () => {
      // The override must win for every provider family, not just the model
      // whose bundled prompt would otherwise be selected.
      for (const id of ["claude-sonnet-4", "gpt-5", "gemini-2.5-pro", "anything-else"]) {
        const prompt = SystemPrompt.provider({ api: { id } } as Provider.Model)[0]
        expect(prompt).toBe("You are a custom agent. CUSTOM SYSTEM MARKER")
      }
    })
  })

  test("whitespace-only SYSTEM.md is ignored", () => {
    const home = path.join(scratch, "whitespace")
    fs.mkdirSync(path.join(home, ".opencode"), { recursive: true })
    fs.writeFileSync(path.join(home, ".opencode", "SYSTEM.md"), "   \n  \n")
    withHome(home, () => {
      const prompt = SystemPrompt.provider(model)[0]
      expect(prompt).not.toContain("CUSTOM SYSTEM MARKER")
    })
  })

  test("empty ~/.opencode falls back to XDG config dir SYSTEM.md", () => {
    const home = path.join(scratch, "xdg-fallback")
    fs.mkdirSync(path.join(home, ".opencode"), { recursive: true })
    const xdg = path.join(home, "xdg-config")
    fs.mkdirSync(path.join(xdg, "opencode"), { recursive: true })
    fs.writeFileSync(
      path.join(xdg, "opencode", "SYSTEM.md"),
      "You are an XDG custom agent. XDG MARKER",
    )
    withHome(home, () => {
      const previousXdg = process.env.XDG_CONFIG_HOME
      process.env.XDG_CONFIG_HOME = xdg
      try {
        const prompt = SystemPrompt.provider(model)[0]
        expect(prompt).toContain("XDG MARKER")
      } finally {
        if (previousXdg === undefined) delete process.env.XDG_CONFIG_HOME
        else process.env.XDG_CONFIG_HOME = previousXdg
      }
    })
  })
})
