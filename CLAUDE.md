# CLAUDE.md — Project Context

## What this is
Daily Stoic — a single-page app where users read rotating Stoic quotes and submit personal questions to a wisdom curator. Curators answer via a separate dashboard; users see responses in "My Requests".

## Files
- `daily-stoic.html` — the user-facing app (React 18 + Tailwind via CDN, no build step)
- `CLAUDE.md` — this file
- Everything else in this repo is unrelated (conversational archives, Canvas files, etc.)

## Supabase
- Project URL: `https://nqdcmvseuuilrlfijyai.supabase.co`
- Table: `wisdom_requests`
- Columns: `id, user_id (uuid), question, response, status, submitted_at, answered_at, share_offered, shared_wisdom_id`
- RLS: anon can SELECT (own rows) + INSERT. Curator policies allow full SELECT + UPDATE.

## Curator dashboard
- File: `C:\Users\edwar\Desktop\Sentinel\curator-dashboard.html`
- Serve with: `python -m http.server 8080` from that folder
- URL: `http://localhost:8080/curator-dashboard.html`
- Handles response + status + answered_at in one submit action

## User identity
Anonymous UUID generated on first app load, stored in `localStorage` as `stoicUserId`. No Supabase auth. Users lose request history if localStorage is cleared.

## Known issues / TODO
- Only 2 hardcoded quotes — needs a larger pool or a Supabase `quotes` table
- No notification (email/push) when a request is answered
- No real auth — `localStorage` UUID is not cryptographically tied to the user

## Deploy workflow
```
cd C:\Users\edwar\Documents\S3NT1NEL27.github.io
git add daily-stoic.html
git commit -m "your message"
git push
```
Live at `https://s3nt1nel27.github.io/daily-stoic.html` within ~1 minute.
