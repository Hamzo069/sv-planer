-- SV-Planer: Öffentliche SV-Seite
-- Einmal im Supabase-Dashboard unter "SQL Editor" einfügen und ausführen ("Run").
-- Gefahrlos mehrfach ausführbar.

-- 1) Tabelle: enthält genau eine Zeile ("main") mit dem veröffentlichten Stand
create table if not exists public.public_page (
  id         text primary key,
  daten      jsonb not null,
  updated_at timestamptz not null default now()
);

-- 2) Zugriff: schreiben und lesen nur die angemeldeten Konten, Besucher nur über die Funktion unten
alter table public.public_page enable row level security;

drop policy if exists "page_auth_all" on public.public_page;
create policy "page_auth_all" on public.public_page
  for all to authenticated using (true) with check (true);

revoke all on public.public_page from anon;
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on public.public_page to authenticated;

-- 3) Funktion für die öffentliche Seite (liefert nur den veröffentlichten Stand)
create or replace function public.get_page(p_id text default 'main')
returns json
language sql
security definer
set search_path = public
stable
as $$
  select daten::json from public.public_page where id = p_id;
$$;

revoke all on function public.get_page(text) from public;
grant execute on function public.get_page(text) to anon, authenticated;
