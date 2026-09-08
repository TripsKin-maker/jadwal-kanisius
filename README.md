# Jadwal Kanisius — online multi-device version

This version stores **Tugas / PR / Ulangan** in Supabase instead of browser-only `localStorage`.

## What now works

- Sign up with a real email and password; existing provisioned users can also log in with their username.
- Accounts that choose the same class share one assignment list.
- A save on one device appears on another device automatically through Supabase Realtime (with a 20-second refresh fallback).
- Each person's **Selesai** checkmarks remain private to their own account.
- Shared assignments can be added, edited, or deleted by class members.
- Row-level security prevents an account from opening another class's data.
- A cloud status indicator shows `Online`, `Menyinkronkan`, or an error.

## One-time database setup

1. Open the Supabase project already configured in `index.html`.
2. Go to **SQL Editor → New query**.
3. Paste and run all of `supabase-setup.sql`.
4. Go to **Authentication → URL Configuration**.
5. Set **Site URL** to the final hosted address and add that same address under **Redirect URLs**. A wildcard such as `https://your-site.netlify.app/**` is convenient.

Email confirmation is enabled on the connected Supabase project. New users must click the confirmation link before their first login.

## Put the site online

Deploy `index.html` as a static site. Easy options:

- **Netlify Drop:** drag this folder to `https://app.netlify.com/drop`.
- **Cloudflare Pages:** create a Pages project and upload the folder.
- **GitHub Pages:** commit `index.html` at the site root and enable Pages.

No private database secret is inside the page. The included Supabase publishable key is intended for browser use; access is protected by Auth and the SQL row-level-security policies.

## How to test sharing

1. Device A: choose **Buat akun**, enter an email, choose a class, confirm the email, then log in.
2. Device B / your friend: create a different account and choose the **same class**.
3. Device A: add an assignment.
4. Device B: it should appear automatically; if Realtime is delayed, the fallback refresh runs within 20 seconds.

Choosing a different class intentionally gives a separate list.
