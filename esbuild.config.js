const path = require("path");
const rails = require("esbuild-rails");
const esbuild = require("esbuild");

const configs = [
  { entry: "application.js", out: "app/assets/builds" },
  { entry: "jil.js", out: "app/assets/builds" },
  { entry: "sortable_standalone.js", out: "app/assets/builds" }
];

const isWatching = process.argv.includes("--watch");

configs.forEach(({ entry, out }) => {
  esbuild.build({
    entryPoints: [entry],
    bundle: true,
    outdir: path.join(process.cwd(), out),
    absWorkingDir: path.join(process.cwd(), "app/javascript"),
    watch: isWatching && {
      onRebuild(error, result) {
        if (error) {
          console.error("Watch build failed:", error);
        } else {
          console.log("Watch build succeeded:", result);
        }
      }
    },
    plugins: [rails()],
  }).catch(() => process.exit(1));
});
