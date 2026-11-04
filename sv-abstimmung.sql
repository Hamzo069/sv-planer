-- SV-Planer: Online-Abstimmung (mit mehreren Fragen und Freitext)
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

-- Mehrere Fragen und Freitext (neu): Fragenliste je Umfrage und Antworten dazu
alter table public.polls add column if not exists fragen jsonb;      -- [{"id","text","typ":"wahl|frei","optionen":[{"id","text"}]}]

create table if not exists public.poll_answers (
  id        bigint generated always as identity primary key,
  poll_id   text not null references public.polls(id) on delete cascade,
  token     text not null,
  q_id      text not null,
  option_id text,
  freitext  text check (freitext is null or char_length(freitext) <= 500),
  created_at timestamptz not null default now()
);
create index if not exists poll_answers_poll on public.poll_answers (poll_id, q_id);

-- 2) Zugriff: nur angemeldete Konten (die zwei SV-Zugänge) direkt, Besucher nur über Funktionen

alter table public.polls      enable row level security;
alter table public.poll_codes enable row level security;
alter table public.votes      enable row level security;
alter table public.poll_answers enable row level security;   -- keine Policy: nur die Funktionen unten kommen heran

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

revoke all on public.polls, public.poll_codes, public.votes, public.poll_answers from anon;
revoke all on public.poll_answers from authenticated;

-- Tabellenrechte für die angemeldeten Konten (neue Supabase-Projekte vergeben sie nicht mehr automatisch)
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on public.polls      to authenticated;
grant select, insert, update, delete on public.poll_codes to authenticated;
grant delete                          on public.votes     to authenticated;

-- 3) Funktionen -------------------------------------------------------------

-- Umfrage für die Abstimmungsseite laden (ohne Codes, ohne Stimmen)
create or replace function public.get_poll(p_id text)
returns json
language sql
security definer
set search_path = public
stable
as $$
  select json_build_object('id', id, 'frage', frage, 'optionen', optionen, 'fragen', fragen,
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

-- Antworten auf mehrere Fragen abgeben (Auswahl und Freitext)
create or replace function public.cast_answers(p_poll text, p_token text, p_code text, p_answers jsonb)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  pl public.polls;
  tok text;
  cc text;
  a jsonb;
  q jsonb;
  qid text;
  oid text;
  txt text;
  n int := 0;
begin
  select * into pl from public.polls where id = p_poll;
  if not found then return 'unbekannt'; end if;
  if pl.status <> 'offen' then return 'geschlossen'; end if;
  if pl.fragen is null or jsonb_typeof(pl.fragen) <> 'array' then return 'unbekannt'; end if;
  if p_answers is null or jsonb_typeof(p_answers) <> 'array' or jsonb_array_length(p_answers) = 0
     or jsonb_array_length(p_answers) > 50 then return 'option'; end if;
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
  -- eine Teilnahme pro Gerät/Code (wie bei der einfachen Abstimmung)
  insert into public.votes (poll_id, option_id, token) values (p_poll, '*', tok);
  for a in select * from jsonb_array_elements(p_answers) loop
    qid := a->>'q';
    select e into q from jsonb_array_elements(pl.fragen) e where e->>'id' = qid limit 1;
    if q is null then raise exception 'frage'; end if;
    if q->>'typ' = 'frei' then
      txt := left(trim(coalesce(a->>'t', '')), 500);
      if txt <> '' then
        insert into public.poll_answers (poll_id, token, q_id, freitext) values (p_poll, tok, qid, txt);
        n := n + 1;
      end if;
    else
      oid := a->>'o';
      if oid is null or not exists (select 1 from jsonb_array_elements(q->'optionen') o where o->>'id' = oid) then
        raise exception 'option';
      end if;
      insert into public.poll_answers (poll_id, token, q_id, option_id) values (p_poll, tok, qid, oid);
      n := n + 1;
    end if;
  end loop;
  if n = 0 then raise exception 'leer'; end if;
  return 'ok';
exception
  when unique_violation then return 'doppelt';
  when raise_exception then
    if sqlerrm in ('frage', 'option', 'leer') then return 'option'; end if;
    raise;
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
                              where poll_id = p_id and option_id <> '*' group by option_id) t), '{}'::json),
    'total',  (select count(*) from public.votes where poll_id = p_id),
    'codes',  (select count(*) from public.poll_codes where poll_id = p_id),
    'qcounts', coalesce((select json_object_agg(q_id, c)
                         from (select q_id, json_object_agg(option_id, n) as c
                               from (select q_id, option_id, count(*) as n from public.poll_answers
                                     where poll_id = p_id and option_id is not null
                                     group by q_id, option_id) a
                               group by q_id) b), '{}'::json),
    'texts',  coalesce((select json_object_agg(q_id, t)
                        from (select q_id, json_agg(freitext order by id) as t from public.poll_answers
                              where poll_id = p_id and freitext is not null
                              group by q_id) c), '{}'::json)
  );
$$;

revoke all on function public.get_poll(text)                      from public;
revoke all on function public.cast_vote(text, text, text, text)   from public;
revoke all on function public.cast_answers(text, text, text, jsonb) from public;
revoke all on function public.poll_results(text)                  from public;
grant execute on function public.get_poll(text)                    to anon, authenticated;
grant execute on function public.cast_vote(text, text, text, text) to anon, authenticated;
grant execute on function public.cast_answers(text, text, text, jsonb) to anon, authenticated;
grant execute on function public.poll_results(text)                to authenticated;
