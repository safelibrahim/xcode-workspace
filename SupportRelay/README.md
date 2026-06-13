# Rewindpad Support Relay

A tiny Cloudflare Worker that receives support messages from the Mac app and
emails them to safelibrahim@gmail.com via Resend. Both services are free at
this volume.

## Deploy (~5 minutes)

1. **Resend** — sign up at <https://resend.com> (free tier: 100 emails/day).
   Create an API key under *API Keys*.

2. **Cloudflare Worker** — sign up at <https://dash.cloudflare.com>
   (free tier: 100k requests/day).
   - *Workers & Pages → Create → Worker*, name it `rewindpad-support`.
   - Replace the generated code with the contents of `worker.js`.
   - *Settings → Variables → Add secret*: name `RESEND_API_KEY`,
     value = your Resend API key.
   - Deploy. Note the URL, e.g. `https://rewindpad-support.<you>.workers.dev`.

3. **Point the app at it** — in `RewindpadMac/ContentView.swift`, update:

   ```swift
   enum SupportRelay {
       static let endpoint = URL(string: "https://rewindpad-support.<you>.workers.dev/send")!
   ```

   (Any path works; the worker answers every POST.)

4. Rebuild the app. Done — Send in the support sheet now delivers directly.

## Notes

- The `X-Rewindpad-Token` header is a shared constant in app + worker. It
  keeps random drive-by POSTs out but isn't a secret (it ships in the app
  binary). Resend's daily cap is the real abuse limit.
- Until the endpoint is configured, the app automatically falls back to
  sending through the user's Mail app, then to a pre-filled compose draft.
- To send from your own domain instead of `onboarding@resend.dev`, verify a
  domain in Resend and change the `from` line in `worker.js`.
