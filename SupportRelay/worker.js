// Rewindpad support relay — Cloudflare Worker.
// Receives support messages from the Mac app and emails them via Resend.
// Deploy steps: see README.md next to this file.

const TOKEN = "rwp_support_v1";              // must match SupportRelay.token in the app
const TO = "safelibrahim@gmail.com";

export default {
  async fetch(request, env) {
    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }
    if (request.headers.get("X-Rewindpad-Token") !== TOKEN) {
      return new Response("Forbidden", { status: 403 });
    }

    let data;
    try {
      data = await request.json();
    } catch {
      return new Response("Bad request", { status: 400 });
    }

    const topic = String(data.topic ?? "Support").slice(0, 100);
    const message = String(data.message ?? "").slice(0, 10_000);
    const replyTo = String(data.replyTo ?? "").slice(0, 200);
    const appVersion = String(data.appVersion ?? "?").slice(0, 30);
    const macos = String(data.macos ?? "?").slice(0, 60);
    if (!message.trim()) {
      return new Response("Empty message", { status: 400 });
    }

    const payload = {
      from: "Launchpad Support <onboarding@resend.dev>",
      to: [TO],
      subject: `${topic} — Launchpad`,
      text: `${message}\n\n—\nFrom: ${replyTo || "not provided"}\nApp ${appVersion} · ${macos}`,
    };
    if (replyTo.includes("@")) payload.reply_to = replyTo;

    const resp = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.RESEND_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
    });

    return new Response(resp.ok ? "ok" : "send failed", {
      status: resp.ok ? 200 : 502,
    });
  },
};
