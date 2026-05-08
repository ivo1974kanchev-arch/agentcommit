# agentcommit

**Git for AI agents.** Commit, diff, and rollback anything your AI agent touches — file writes, shell commands, tool calls — with full session history and semantic search.

## Quick Start

1. **Clone & install**
   ```bash
   git clone https://github.com/your-org/agentcommit && cd agentcommit
   npm install
   ```
2. **Configure environment**
   ```bash
   cp .env.example .env.local
   # Fill in Supabase URL/keys and any auth secrets
   ```
3. **Apply database schema**
   ```bash
   psql $DATABASE_URL -f schema.sql
   # Or paste into Supabase SQL Editor
   ```
4. **Run locally**
   ```bash
   npm run dev        # Next.js on :3000
   npm run api:dev    # Hono edge API on :3001
   ```

## Environment Variables

| Variable | Description |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | Supabase project URL |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Supabase anon/public key |
| `SUPABASE_SERVICE_ROLE_KEY` | Service role key (server-only) |
| `DATABASE_URL` | Direct Postgres connection string |
| `CLI_JWT_SECRET` | Secret for signing CLI auth tokens |
| `OPENAI_API_KEY` | Used for pgvector embedding of prompt summaries |
| `NEXT_PUBLIC_APP_URL` | Canonical app URL (e.g. https://agentcommit.dev) |
| `STRIPE_SECRET_KEY` | Stripe secret for billing |
| `STRIPE_WEBHOOK_SECRET` | Stripe webhook signing secret |
| `NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY` | Stripe publishable key |

## Deploy Notes

- **Frontend + API routes**: Deploy to Vercel; set all env vars in project settings. Hono handlers live in `app/api/[...route]/route.ts` as Edge Runtime.
- **Supabase**: Enable `pgvector` extension in SQL Editor (`create extension if not exists vector`). Realtime is enabled per-table in the Supabase dashboard. Estimated ~$45/mo on Pro plan.
- **Migrations**: Use Supabase CLI (`supabase db push`) for production migrations.