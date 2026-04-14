import { describe, it, expect, beforeAll, afterAll, vi } from "vitest"
import request from "supertest"
import type { Server } from "http"

vi.mock("axios", () => {
  const get = vi.fn(async (url: string) => {
    if (url.endsWith("/runtimes")) {
      return { data: [{ language: "python", version: "3.12.0", aliases: ["py"] }] }
    }
    throw new Error("unexpected get: " + url)
  })
  const post = vi.fn(async (url: string, body: any) => {
    if (url.endsWith("/execute")) {
      return { data: { run: { stdout: "hi\n", stderr: "", code: 0 }, language: body.language } }
    }
    throw new Error("unexpected post: " + url)
  })
  return { default: { create: () => ({ get, post }), get, post } }
})

let server: Server

beforeAll(async () => {
  process.env.CORS_ORIGIN = "*"
  process.env.PORT = "0"
  process.env.PISTON_URL = "http://piston-mock/api/v2"
  const mod = await import("../src/server")
  server = (mod as any).server
})

afterAll(() => new Promise<void>((resolve) => server.close(() => resolve())))

describe("/api/piston proxy", () => {
  it("GET /api/piston/runtimes returns upstream list", async () => {
    const res = await request(server).get("/api/piston/runtimes")
    expect(res.status).toBe(200)
    expect(res.body).toEqual([
      { language: "python", version: "3.12.0", aliases: ["py"] },
    ])
  })

  it("POST /api/piston/execute forwards body and returns result", async () => {
    const res = await request(server)
      .post("/api/piston/execute")
      .send({
        language: "python",
        version: "3.12.0",
        files: [{ name: "main.py", content: "print('hi')" }],
        stdin: "",
      })
    expect(res.status).toBe(200)
    expect(res.body.run.stdout).toBe("hi\n")
  })

  it("returns 502 when Piston is unreachable", async () => {
    const axios = (await import("axios")).default as any
    axios.get.mockRejectedValueOnce(new Error("ECONNREFUSED"))
    const res = await request(server).get("/api/piston/runtimes")
    expect(res.status).toBe(502)
  })
})
