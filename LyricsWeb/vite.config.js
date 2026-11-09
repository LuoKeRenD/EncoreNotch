import { defineConfig } from "vite";

// The output is committed, so building the app does not need Node.
export default defineConfig({
  base: "./",
  build: {
    outDir: "../boringNotch/Lyrics/LyricsWeb",
    emptyOutDir: true,
    assetsDir: "assets",
    target: "safari16",
    chunkSizeWarningLimit: 2000,
    rollupOptions: {
      output: {
        entryFileNames: "assets/lyrics.js",
        chunkFileNames: "assets/[name].js",
        assetFileNames: "assets/[name][extname]",
      },
    },
  },
});
