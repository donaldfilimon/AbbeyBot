import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// Emit into AbbeyServer's SPM resource tree so FileMiddleware can serve the SPA.
export default defineConfig({
  plugins: [react()],
  build: {
    outDir: "../Sources/AbbeyServer/Resources/Public",
    emptyOutDir: true,
  },
});
