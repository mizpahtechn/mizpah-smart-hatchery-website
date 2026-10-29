# Mizpah website enquiry email endpoint

This Worker is a server-side replacement for the website's FormSubmit dependency. It sends enquiries through Resend to the official admin mailbox, `info@mizpahtechnology.com.ng`, and sets the customer's address as Reply-To. The Resend API key stays in Cloudflare's encrypted Worker secrets and is never placed in public website code.

## Important status

Adding this source file does **not** deploy the Worker and does not change the live website form yet. The form should only be switched after the Worker is deployed and its endpoint URL is known. This avoids breaking the live website while the replacement is being configured.

## 1. Confirm Resend sender verification

Sign in to Resend and check that `mizpahtechnology.com.ng` is verified under Domains. DNS records alone do not prove verification. Create an API key with permission to send email.

Official dashboard: https://resend.com/

## 2. Create the Worker

1. Sign in to Cloudflare: https://dash.cloudflare.com/
2. Open **Workers & Pages** and create a Worker named `mizpah-contact`.
3. Replace the starter code with the full contents of `server/contact-worker.js` from this repository and deploy.
4. Open the Worker settings and add:
   - **Secret** `RESEND_API_KEY`: the API key generated in Resend.
   - **Variable** `ADMIN_EMAIL`: `info@mizpahtechnology.com.ng`
   - **Variable** `FROM_EMAIL`: a sender identity that Resend confirms is verified, for example `Mizpah Website <website@mizpahtechnology.com.ng>` only if that sender is allowed by your verified domain.
5. Copy the Worker URL ending in `.workers.dev`.

Do not send API keys, mailbox passwords, or other secrets in this chat or commit them to GitHub.

## 3. Verify before switching the website form

- Open the Worker URL in a browser. A 405 response is expected because the endpoint accepts POST only.
- Submit a test POST using the website form only after the front end has been pointed at the Worker.
- Check Resend's email logs and the Zoho inbox/spam folder.
- A success response means Resend accepted the email request; it is not proof the message reached the inbox. Confirm actual receipt in Zoho before treating the workflow as verified.

## Endpoint behavior

- Allows requests only from `https://mizpahtechnology.com.ng` and `https://www.mizpahtechnology.com.ng`.
- Validates required fields and email format; caps input lengths.
- Includes a honeypot field to suppress simple bot submissions.
- Sends plain-text email to the admin, with the visitor's email as Reply-To.
- Does not expose provider errors or secrets to website visitors.
