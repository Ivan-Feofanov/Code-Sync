import axios, { AxiosInstance } from "axios"

const backendUrl = import.meta.env.VITE_BACKEND_URL || "http://localhost:3000"
const pistonBaseUrl = `${backendUrl}/api/piston`

const instance: AxiosInstance = axios.create({
    baseURL: pistonBaseUrl,
    headers: {
        "Content-Type": "application/json",
    },
})

export default instance
