// Local fixture only. Tests temporarily replace the pinned package entrypoint
// inside a disposable runtime; this is not a Harness implementation.
const fs = require("node:fs");
const http = require("node:http");
const { spawn } = require("node:child_process");

const portIndex = process.argv.indexOf("--port");
const port = Number(portIndex >= 0 ? process.argv[portIndex + 1] : 3080);
const record = process.env.PZ_DSH_FIXTURE_RECORD;
const sensitive = ["DEEPSEEK_API_KEY", "OPENAI_API_KEY", "AWS_SECRET_ACCESS_KEY", "NODE_AUTH_TOKEN"];
const nodeConfig = ["NODE_PATH", "NODE_EXTRA_CA_CERTS", "NPM_CONFIG_USERCONFIG"];

if (process.env.PZ_DSH_FIXTURE_CRASH === "1") process.exit(19);

if (record) {
  fs.writeFileSync(record, JSON.stringify({
    processId: process.pid,
    descendantProcessId: 0,
    cwd: process.cwd(),
    dshHome: process.env.DSH_HOME || "",
    route: (process.env.DSH_HOME || "").split(/[\\/]/).filter(Boolean).pop() || "",
    permission: process.env.DSH_PERMISSION_MODE || "",
    telemetry: process.env.DSH_TELEMETRY_DISABLED || "",
    leakedNames: sensitive.filter((name) => Boolean(process.env[name])),
    nodeOptions: process.env.NODE_OPTIONS || "",
    nodeConfigNames: nodeConfig.filter((name) => Boolean(process.env[name])),
  }));
}

console.log(`dsh web: http://127.0.0.1:${port}/?token=fixture-launch-secret`);
console.log("apiKey=fixture-visible-secret");
http.createServer((request, response) => {
  const requestRecord = process.env.PZ_DSH_FIXTURE_REQUEST_RECORD;
  if (requestRecord) fs.writeFileSync(requestRecord, request.url || "");
  response.writeHead(200, { "content-type": "text/plain" });
  response.end("fixture only");
}).listen(port, "127.0.0.1");

// Child process reproduces an upstream descendant that can outlive its
// direct Node parent unless the supervisor owns the full Windows process job.
setTimeout(() => {
  const saveDescendantState = (pid, errorCode = "") => {
    if (!record) return;
    const state = JSON.parse(fs.readFileSync(record, "utf8"));
    state.descendantProcessId = pid || 0;
    state.descendantError = /^[A-Z0-9_-]{1,32}$/.test(errorCode) ? errorCode : "";
    fs.writeFileSync(record, JSON.stringify(state));
  };
  try {
    const descendant = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], {
      cwd: process.cwd(), stdio: "ignore", windowsHide: true,
    });
    descendant.once("error", (error) => saveDescendantState(0, String(error.code || "SPAWN-ERROR")));
    if (descendant.pid) saveDescendantState(descendant.pid);
  } catch (error) {
    saveDescendantState(0, String(error.code || "SPAWN-ERROR"));
  }
}, 500);
