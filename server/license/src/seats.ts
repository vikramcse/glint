// A tiny self-service page: a buyer proves ownership with their key and purchase email,
// sees which Macs hold seats, and frees one (for example a Mac they no longer have).

import type { Dependencies } from "./index.ts";
import { hashEmail, TokenError, verifyToken } from "./tokens.ts";

export async function seatsPage(request: Request, deps: Dependencies): Promise<Response> {
  if (request.method === "GET") return page(form());
  const data = await request.formData();
  const key = String(data.get("key") ?? "").trim();
  const email = String(data.get("email") ?? "").trim();
  const free = data.get("free");

  let licenseID: string;
  try {
    const payload = await verifyToken(key, deps.keys, { kind: "license" });
    if (payload.emailHash !== (await hashEmail(email))) return page(form("That key and email don’t match.", key), 403);
    licenseID = payload.licenseID;
  } catch (error) {
    if (error instanceof TokenError) return page(form("That doesn’t look like a Glint license key.", key), 422);
    throw error;
  }

  let notice = "";
  if (typeof free === "string" && free.length > 0) {
    notice = (await deps.store.releaseSeat(licenseID, free)) ? "Seat freed. Activate Glint on your other Mac." : "";
  }
  const license = await deps.store.license(licenseID);
  const activations = await deps.store.activations(licenseID);
  const seats = license?.seats ?? 2;
  const rows = activations
    .map(
      (activation) => `
      <li>
        <span>Mac …${escape(activation.install_id.slice(-6))} · activated ${date(activation.activated_at)} · last seen ${date(activation.last_seen_at)}</span>
        <form method="post">
          <input type="hidden" name="key" value="${escape(key)}">
          <input type="hidden" name="email" value="${escape(email)}">
          <button name="free" value="${escape(activation.install_id)}">Free this seat</button>
        </form>
      </li>`,
    )
    .join("");
  return page(`
    ${notice ? `<p class="notice">${escape(notice)}</p>` : ""}
    <p>${activations.length} of ${seats} seats in use.</p>
    <ul>${rows || "<li>No Macs are using this license.</li>"}</ul>`);
}

function form(error = "", key = ""): string {
  return `
    ${error ? `<p class="error">${escape(error)}</p>` : ""}
    <form method="post">
      <label>License key <textarea name="key" rows="3" required>${escape(key)}</textarea></label>
      <label>Purchase email <input type="email" name="email" required></label>
      <button>Show my Macs</button>
    </form>`;
}

function page(content: string, status = 200): Response {
  const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Glint Pro seats</title>
<style>
  :root { color-scheme: light dark; font: 15px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; }
  body { max-width: 34rem; margin: 3rem auto; padding: 0 1rem; }
  label { display: block; margin: 0 0 1rem; } textarea, input { display: block; width: 100%; font: inherit; margin-top: .25rem; }
  textarea { font-family: ui-monospace, monospace; } li { margin: .5rem 0; } li form { display: inline; margin-left: .5rem; }
  .error { color: #d70015; } .notice { color: #248a3d; }
</style></head>
<body><h1>Glint Pro seats</h1>${content}</body></html>`;
  return new Response(html, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'",
    },
  });
}

function date(seconds: number): string {
  return new Date(seconds * 1000).toISOString().slice(0, 10);
}

function escape(text: string): string {
  return text.replace(/[&<>"']/g, (char) => `&#${char.charCodeAt(0)};`);
}
