import { describe, it, expect, beforeAll, afterAll } from "vitest"
import request from "supertest"
import type { Server } from "http"

let server: Server

beforeAll(async () => {
  process.env.CORS_ORIGIN = "https://interview.example.com"
  process.env.PORT = "0"
  // Import after env is set so the module reads it.
  const mod = await import("../src/server")
  server = (mod as any).server
})

afterAll(() => new Promise<void>((resolve) => server.close(() => resolve())))

describe("CORS", () => {
  it("echoes the configured origin when it matches", async () => {
    const res = await request(server)
      .options("/api/piston/runtimes")
      .set("Origin", "https://interview.example.com")
      .set("Access-Control-Request-Method", "GET")
    expect(res.headers["access-control-allow-origin"]).toBe(
      "https://interview.example.com",
    )
  })

  it("rejects a non-allowed origin", async () => {
    const res = await request(server)
      .options("/api/piston/runtimes")
      .set("Origin", "https://evil.example.com")
      .set("Access-Control-Request-Method", "GET")
    expect(res.headers["access-control-allow-origin"]).toBeUndefined()
  })
})
