import { execFile } from "node:child_process";
const providerID = "phasezero-openai-api";

export async function authorizeRequest(event, resolveCredential) {
  const request = event.request;
  if (!["https://api.openai.com/v1/chat/completions", "https://api.openai.com/v1/responses"].includes(request.url)) {
    throw new Error("PhaseZero: destino API não autorizado");
  }
  const credential = await resolveCredential(request.url);
  const body = await request.clone().json();
  if (body.model !== credential.model) throw new Error("PhaseZero: modelo fora da conexão autorizada");
  request.headers.set("authorization", `Bearer ${credential.key}`);
  request.headers.set("OpenAI-Organization", credential.organization);
  request.headers.set("OpenAI-Project", credential.project);
  request.headers.delete("api-key");
  event.request = new Request(request, { redirect: "error" });
}

export default {
  id: "phasezero.openai-api",
  async setup(ctx) {
    if (typeof ctx.session?.hook !== "function") throw new Error("PhaseZero: versão OpenCode sem hooks necessários");
    const { python, manager } = ctx.options;
    if (typeof python !== "string" || typeof manager !== "string") throw new Error("PhaseZero: integração incompleta");
    const credential = (url) => new Promise((resolve, reject) => {
      let child;
      child = execFile(python, ["-I", manager, "credential"], { timeout: 10000, maxBuffer: 131072, encoding: "utf8" }, (error, stdout) => {
        if (error) return reject(new Error("PhaseZero: conexão revogada ou indisponível"));
        try { resolve(JSON.parse(stdout)); } catch { reject(new Error("PhaseZero: resposta do cofre inválida")); }
      });
      child.stdin.on("error", () => {});
      child.stdin.end(JSON.stringify({ url }));
    });
    await ctx.session.hook("http.request", (event) => authorizeRequest(event, credential), { providerID });
    await ctx.session.hook("experimental.ws.handshake", () => { throw new Error("PhaseZero: somente transporte HTTP autorizado"); }, { providerID });
    await ctx.session.hook("retry", (event) => {
      const code = String(event.error?.code || event.error?.type || "");
      if (event.error?.status === 401 || /credit_balance_exhausted|insufficient_quota/.test(code)) event.decision = { retry: false };
    }, { providerID });
  },
};
