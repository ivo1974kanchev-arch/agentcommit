-- agentcommit database schema
-- PostgreSQL / Supabase
-- Run: psql $DATABASE_URL -f schema.sql

-- ─── Extensions ───────────────────────────────────────────────────────────────
create extension if not exists vector;
create extension if not exists pg_trgm; -- for fuzzy text search on prompt_summary

-- ─── ENUM types ───────────────────────────────────────────────────────────────
create type plan_tier        as enum ('free', 'pro', 'team');
create type session_status   as enum ('running', 'success', 'interrupted', 'failed');
create type action_type      as enum ('file_write', 'shell_exec', 'tool_call');
create type tag_entity_type  as enum ('commit', 'session');

-- ─── users ────────────────────────────────────────────────────────────────────
create table users (
  id              uuid primary key references auth.users(id) on delete cascade,
  email           text not null,
  plan            plan_tier not null default 'free',
  cli_auth_token  text unique,                  -- hashed CLI token
  created_at      timestamptz not null default now()
);
alter table users enable row level security;
create policy "users: self read/write"
  on users for all
  using  (auth.uid() = id)
  with check (auth.uid() = id);

-- ─── projects ─────────────────────────────────────────────────────────────────
create table projects (
  id                uuid primary key default gen_random_uuid(),
  owner_user_id     uuid not null references users(id) on delete cascade,
  name              text not null,
  path              text not null,
  agent_type_default text,                      -- e.g. 'claude', 'cursor', 'copilot'
  created_at        timestamptz not null default now()
);
alter table projects enable row level security;
create policy "projects: owner access"
  on projects for all
  using  (auth.uid() = owner_user_id)
  with check (auth.uid() = owner_user_id);

-- ─── sessions ─────────────────────────────────────────────────────────────────
create table sessions (
  id              uuid primary key default gen_random_uuid(),
  project_id      uuid not null references projects(id) on delete cascade,
  agent_type      text not null,                -- 'claude' | 'cursor' | 'copilot' | custom
  start_time      timestamptz not null default now(),
  end_time        timestamptz,
  status          session_status not null default 'running',
  prompt_summary  text,
  embedding       vector(1536)                  -- pgvector: openai text-embedding-3-small
);
alter table sessions enable row level security;
create policy "sessions: project owner access"
  on sessions for all
  using (
    exists (
      select 1 from projects p
      where p.id = sessions.project_id
        and p.owner_user_id = auth.uid()
    )
  );
-- Semantic search index
create index sessions_embedding_idx
  on sessions using ivfflat (embedding vector_cosine_ops)
  with (lists = 100);
-- Trigram index for keyword search on prompt_summary
create index sessions_prompt_trgm_idx
  on sessions using gin (prompt_summary gin_trgm_ops);

-- ─── commits ──────────────────────────────────────────────────────────────────
create table commits (
  id                  uuid primary key default gen_random_uuid(),
  session_id          uuid not null references sessions(id) on delete cascade,
  commit_hash         text not null unique,
  parent_commit_hash  text,
  message             text,
  created_at          timestamptz not null default now()
);
alter table commits enable row level security;
create policy "commits: session owner access"
  on commits for all
  using (
    exists (
      select 1 from sessions s
      join projects p on p.id = s.project_id
      where s.id = commits.session_id
        and p.owner_user_id = auth.uid()
    )
  );
create index commits_session_id_idx on commits(session_id);
create index commits_parent_hash_idx on commits(parent_commit_hash);

-- ─── file_snapshots ───────────────────────────────────────────────────────────
create table file_snapshots (
  id               uuid primary key default gen_random_uuid(),
  commit_id        uuid not null references commits(id) on delete cascade,
  file_path        text not null,
  content_hash     text not null,
  content          text,                        -- compressed/plain text content
  diff_from_parent text                         -- unified diff vs parent commit
);
alter table file_snapshots enable row level security;
create policy "file_snapshots: commit owner access"
  on file_snapshots for all
  using (
    exists (
      select 1 from commits c
      join sessions s on s.id = c.session_id
      join projects p on p.id = s.project_id
      where c.id = file_snapshots.commit_id
        and p.owner_user_id = auth.uid()
    )
  );
create index file_snapshots_commit_id_idx  on file_snapshots(commit_id);
create index file_snapshots_file_path_idx  on file_snapshots(file_path);
create index file_snapshots_content_hash_idx on file_snapshots(content_hash);

-- ─── agent_actions ────────────────────────────────────────────────────────────
create table agent_actions (
  id             uuid primary key default gen_random_uuid(),
  session_id     uuid not null references sessions(id) on delete cascade,
  action_type    action_type not null,
  payload        jsonb not null default '{}',
  reasoning_text text,
  timestamp      timestamptz not null default now()
);
alter table agent_actions enable row level security;
create policy "agent_actions: session owner access"
  on agent_actions for all
  using (
    exists (
      select 1 from sessions s
      join projects p on p.id = s.project_id
      where s.id = agent_actions.session_id
        and p.owner_user_id = auth.uid()
    )
  );
create index agent_actions_session_id_idx  on agent_actions(session_id);
create index agent_actions_timestamp_idx   on agent_actions(timestamp);
create index agent_actions_payload_gin_idx on agent_actions using gin (payload);

-- ─── blame_annotations ────────────────────────────────────────────────────────
create table blame_annotations (
  id          uuid primary key default gen_random_uuid(),
  project_id  uuid not null references projects(id) on delete cascade,
  file_path   text not null,
  line_number integer not null,
  commit_id   uuid not null references commits(id) on delete cascade,
  session_id  uuid not null references sessions(id) on delete cascade,
  refreshed_at timestamptz not null default now()
);
alter table blame_annotations enable row level security;
create policy "blame_annotations: project owner access"
  on blame_annotations for all
  using (
    exists (
      select 1 from projects p
      where p.id = blame_annotations.project_id
        and p.owner_user_id = auth.uid()
    )
  );
create unique index blame_annotations_unique_idx
  on blame_annotations(project_id, file_path, line_number);
create index blame_annotations_project_file_idx
  on blame_annotations(project_id, file_path);

-- ─── tags ─────────────────────────────────────────────────────────────────────
create table tags (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references users(id) on delete cascade,
  entity_type  tag_entity_type not null,
  entity_id    uuid not null,
  label        text not null,
  created_at   timestamptz not null default now(),
  unique (user_id, entity_type, entity_id, label)
);
alter table tags enable row level security;
create policy "tags: owner access"
  on tags for all
  using  (auth.uid() = user_id)
  with check (auth.uid() = user_id);
create index tags_entity_idx on tags(entity_type, entity_id);
create index tags_label_idx  on tags(label);

-- ─── waitlist ─────────────────────────────────────────────────────────────────
create table waitlist (
  id         uuid primary key default gen_random_uuid(),
  email      text not null unique,
  plan_interest text,                           -- 'solo' | 'pro' | 'team'
  referrer   text,
  created_at timestamptz not null default now()
);
alter table waitlist enable row level security;
-- Anyone can join; nobody can read others' entries via client
create policy "waitlist: insert only"
  on waitlist for insert
  with check (true);
create policy "waitlist: no public reads"
  on waitlist for select
  using (false);