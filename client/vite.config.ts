import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      "/api": { target: "http://localhost:3000", changeOrigin: true, rewrite: (path) => path.replace(/^\/api/, "") },
      "/socket.io": { target: "http://localhost:3000", ws: true },
    },
  },
  test: { environment: "jsdom", setupFiles: "./src/test/setup.ts" },
});
