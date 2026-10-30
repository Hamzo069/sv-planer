-- SV-Planer: Online-Abstimmung
-- Einmal im Supabase-Dashboard unter "SQL Editor" einfügen und ausführen ("Run").
-- Gefahrlos mehrfach ausführbar.

-- 1) Tabellen -------------------------------------------------------------

create table if not exists public.polls (
  id         text primary key,
  frage      text not null,
  optionen   jsonb not null,                       -- [{"id":"...","text":"..."}]
  modus      text not null default 'einfach' check (modus in ('einfach','codes')),
  status     text not null default 'offen'   check (status in ('offen','zu')),
  created_at timestamptz not null default now()
);

create table if not exists public.poll_codes (
  poll_id text not null references public.polls(id) on delete cascade,
  code    text not null,
  primary key (poll_id, code)
);

create table if not exists public.votes (
  id         bigint generated always as identity primary key,
  poll_id    text not null references public.polls(id) on delete cascade,
  option_id  text not null,
  token      text not null,                        -- Gerätekennung oder Einmal-Code, nie ein Name
  created_at timestamptz not null default now(),
  unique (poll_id, token)
);

-- 2) Zugriff: nur angemeldete Konten (die zwei SV-Zugänge) direkt, Besucher nur über Funktionen

alter table public.polls      enable row level security;
alter table public.poll_codes enable row level security;
alter table public.votes      enable row level security;

drop policy if exists "polls_auth_all" on public.polls;
create policy "polls_auth_all" on public.polls
  for all to authenticated using (true) with check (true);

drop policy if exists "codes_auth_all" on public.poll_codes;
create policy "codes_auth_all" on public.poll_codes
  for all to authenticated using (true) with check (true);

-- Stimmen direkt lesen darf niemand; Ergebnisse gibt es nur über poll_results (nur angemeldet).
drop policy if exists "votes_auth_delete" on public.votes;
create policy "votes_auth_delete" on public.votes
  for delete to authenticated using (true);

revoke all on public.polls, public.poll_codes, public.votes from anon;

-- 3) Funktionen -------------------------------------------------------------

-- Umfrage für die Abstimmungsseite laden (ohne Codes, ohne Stimmen)
create or replace function public.get_poll(p_id text)
returns json
language sql
security definer
set search_path = public
stable
as $$
  select json_build_object('id', id, 'frage', frage, 'optionen', optionen,
                           'modus', modus, 'status', status)
  from public.polls where id = p_id;
$$;

-- Stimme abgeben
create or replace function public.cast_vote(p_poll text, p_option text, p_token text, p_code text default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  pl public.polls;
  tok text;
  cc text;
begin
  select * into pl from public.polls where id = p_poll;
  if not found then return 'unbekannt'; end if;
  if pl.status <> 'offen' then return 'geschlossen'; end if;
  if not exists (select 1 from jsonb_array_elements(pl.optionen) o where o->>'id' = p_option) then
    return 'option';
  end if;
  if pl.modus = 'codes' then
    cc := upper(trim(coalesce(p_code, '')));
    if cc = '' or not exists (select 1 from public.poll_codes where poll_id = p_poll and code = cc) then
      return 'code';
    end if;
    tok := 'c:' || cc;
  else
    if p_token is null or length(p_token) < 16 or length(p_token) > 64 then return 'token'; end if;
    tok := 'd:' || p_token;
  end if;
  insert into public.votes (poll_id, option_id, token) values (p_poll, p_option, tok);
  return 'ok';
exception when unique_violation then
  return 'doppelt';
end;
$$;

-- Ergebnis zählen (nur für angemeldete Konten)
create or replace function public.poll_results(p_id text)
returns json
language sql
security definer
set search_path = public
stable
as $$
  select json_build_object(
    'counts', coalesce((select json_object_agg(option_id, n)
                        from (select option_id, count(*) as n from public.votes
                              where poll_id = p_id group by option_id) t), '{}'::json),
    'total',  (select count(*) from public.votes where poll_id = p_id),
    'codes',  (select count(*) from public.poll_codes where poll_id = p_id)
  );
$$;

revoke all on function public.get_poll(text)                      from public;
revoke all on function public.cast_vote(text, text, text, text)   from public;
revoke all on function public.poll_results(text)                  from public;
grant execute on function public.get_poll(text)                    to anon, authenticated;
grant execute on function public.cast_vote(text, text, text, text) to anon, authenticated;
grant execute on function public.poll_results(text)                to authenticated;
