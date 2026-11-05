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

-- 4) Anliegen-Box (anonyme Anliegen der Schülerschaft) ------------------------
-- Besucher können nur über submit_concern etwas einreichen. Lesen, Bearbeiten und
-- Löschen dürfen nur die angemeldeten Konten (im Planer unter "Themen").

create table if not exists public.concern_box (
  id    text primary key default 'main' check (id = 'main'),
  offen boolean not null default false,
  intro text check (intro is null or char_length(intro) <= 300)
);
insert into public.concern_box (id, offen) values ('main', false) on conflict do nothing;

create table if not exists public.concerns (
  id         bigint generated always as identity primary key,
  kat        text not null,
  text       text not null check (char_length(text) between 5 and 600),
  token      text not null,                      -- zufällige Gerätekennung nur gegen Missbrauch, nie ein Name
  status     text not null default 'neu' check (status in ('neu','uebernommen','erledigt','verworfen')),
  created_at timestamptz not null default now()
);
create index if not exists concerns_status on public.concerns (status, created_at desc);

-- Eigene Art (frei beschrieben): neue Spalte und erweiterte Prüfung (gefahrlos wiederholbar)
alter table public.concerns add column if not exists kat_text text;
alter table public.concerns drop constraint if exists concerns_kat_check;
alter table public.concerns add constraint concerns_kat_check
  check (kat in ('unterricht','raeume','organisation','veranstaltung','sonstiges','frei'));
alter table public.concerns drop constraint if exists concerns_kat_text_check;
alter table public.concerns add constraint concerns_kat_text_check
  check ((kat = 'frei' and kat_text is not null and char_length(kat_text) between 2 and 40) or (kat <> 'frei' and kat_text is null));

alter table public.concern_box enable row level security;
alter table public.concerns    enable row level security;

drop policy if exists "concern_box_auth_all" on public.concern_box;
create policy "concern_box_auth_all" on public.concern_box
  for all to authenticated using (true) with check (true);
drop policy if exists "concerns_auth_all" on public.concerns;
create policy "concerns_auth_all" on public.concerns
  for all to authenticated using (true) with check (true);

revoke all on public.concern_box, public.concerns from anon;
grant select, insert, update, delete on public.concern_box to authenticated;
grant select, update, delete         on public.concerns    to authenticated;

-- Zustand der Box für die Einreichungsseite (offen/zu, Begrüßungstext)
create or replace function public.get_concern_box()
returns json
language sql
security definer
set search_path = public
stable
as $$
  select json_build_object('offen', offen, 'intro', intro) from public.concern_box where id = 'main';
$$;

-- Anliegen einreichen (anonym). Rückgabe: ok | geschlossen | token | kat | text | limit
-- Bei p_kat = 'frei' beschreibt p_kat_text die Art selbst (2 bis 40 Zeichen).
drop function if exists public.submit_concern(text, text, text);
create or replace function public.submit_concern(p_kat text, p_text text, p_token text, p_kat_text text default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  t text;
  kt text;
  tok text;
begin
  if not coalesce((select offen from public.concern_box where id = 'main'), false) then return 'geschlossen'; end if;
  if p_token is null or length(p_token) < 16 or length(p_token) > 64 then return 'token'; end if;
  if p_kat is null or p_kat not in ('unterricht','raeume','organisation','veranstaltung','sonstiges','frei') then return 'kat'; end if;
  kt := null;
  if p_kat = 'frei' then
    kt := trim(coalesce(p_kat_text, ''));
    if char_length(kt) < 2 or char_length(kt) > 40 then return 'kat'; end if;
  end if;
  t := trim(coalesce(p_text, ''));
  if char_length(t) < 5 or char_length(t) > 600 then return 'text'; end if;
  tok := 'd:' || p_token;
  -- Missbrauchsschutz: höchstens 5 pro Gerät und Tag, höchstens 300 pro Stunde insgesamt
  if (select count(*) from public.concerns where token = tok and created_at > now() - interval '1 day') >= 5 then return 'limit'; end if;
  if (select count(*) from public.concerns where created_at > now() - interval '1 hour') >= 300 then return 'limit'; end if;
  insert into public.concerns (kat, kat_text, text, token) values (p_kat, kt, t, tok);
  return 'ok';
end;
$$;

revoke all on function public.get_concern_box()                  from public;
revoke all on function public.submit_concern(text, text, text, text) from public;
grant execute on function public.get_concern_box()                to anon, authenticated;
grant execute on function public.submit_concern(text, text, text, text) to anon, authenticated;
