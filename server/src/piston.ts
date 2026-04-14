import { Router, Request, Response } from "express"
import axios from "axios"

const PISTON_URL = process.env.PISTON_URL || "http://localhost:2000/api/v2"

const router = Router()

router.get("/runtimes", async (_req: Request, res: Response) => {
  try {
    const r = await axios.get(`${PISTON_URL}/runtimes`)
    res.json(r.data)
  } catch (err) {
    console.error("piston /runtimes failed:", (err as Error).message)
    res.status(502).json({ error: "piston unreachable" })
  }
})

router.post("/execute", async (req: Request, res: Response) => {
  try {
    const r = await axios.post(`${PISTON_URL}/execute`, req.body)
    res.json(r.data)
  } catch (err) {
    console.error("piston /execute failed:", (err as Error).message)
    res.status(502).json({ error: "piston unreachable" })
  }
})

export default router
