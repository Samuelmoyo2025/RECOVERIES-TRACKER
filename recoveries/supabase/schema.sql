-- =====================================================================
--  ZGI Reinsurance Recoveries Tracker — Supabase schema
--  Run once in Supabase → SQL Editor (safe to re-run: uses IF NOT EXISTS
--  / OR REPLACE where possible).
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. PEOPLE & ROLES
--    admin          : everything, user management, settings, migration
--    finance        : upload claims, record recoveries, VERIFY POPs
--    claims         : upload claims with reinsurance
--    credit_control : follow up, log activity, record recoveries + POP
--    viewer         : read-only (management / audit)
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id               uuid primary key references auth.users on delete cascade,
  email            text,
  full_name        text,
  role             text not null default 'viewer'
                   check (role in ('admin','finance','claims','credit_control','viewer')),
  controller_name  text,              -- the name used in the "Responsible" column, e.g. 'M. Makumbe'
  active           boolean not null default true,
  email_reminders  boolean not null default true,
  created_at       timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email,
          coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  -- the very first user to sign up becomes admin
  if (select count(*) from public.profiles) = 1 then
    update public.profiles set role = 'admin' where id = new.id;
  end if;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.my_role()
returns text language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid() and active
$$;

-- ---------------------------------------------------------------------
-- 2. REFERENCE DATA
-- ---------------------------------------------------------------------
create table if not exists public.reinsurers (
  id             uuid primary key default gen_random_uuid(),
  name           text not null unique,
  contact_name   text,
  contact_email  text,
  default_controller text,          -- new claims for this reinsurer auto-assign to this controller
  active         boolean not null default true,
  created_at     timestamptz not null default now()
);

alter table public.reinsurers add column if not exists default_controller text;

create table if not exists public.settings (
  id                  int primary key default 1 check (id = 1),
  follow_up_days      int  not null default 7,    -- flag a recovery with no activity for N days
  promise_grace_days  int  not null default 0,    -- days after a promised date before it's "broken"
  require_pop         boolean not null default true,
  updated_at          timestamptz not null default now(),
  updated_by          uuid
);
insert into public.settings (id) values (1) on conflict do nothing;

-- secret used by Power Automate to fetch the reminder digest (not readable via API)
create table if not exists public.digest_config (
  id     int primary key default 1 check (id = 1),
  token  text not null default encode(gen_random_bytes(24), 'hex')
);
insert into public.digest_config (id) values (1) on conflict do nothing;

-- ---------------------------------------------------------------------
-- 3. RECOVERIES (one row per claim payment × reinsurer)
--    Rows are NEVER deleted by users. When 100% recovered the status flips
--    to 'recovered' automatically and the row moves to the Archive screen.
-- ---------------------------------------------------------------------
create sequence if not exists public.recovery_ref_seq;

create table if not exists public.recoveries (
  id                     uuid primary key default gen_random_uuid(),
  ref                    text unique not null
                         default 'REC-' || lpad(nextval('public.recovery_ref_seq')::text, 6, '0'),
  currency               text not null check (currency in ('USD','ZWG')),
  date_sent              date not null,             -- date sent to finance
  linear_id              text,
  client_name            text not null,
  claim_number           text not null,
  payee                  text,
  reinsurer              text not null references public.reinsurers(name) on update cascade,
  arrangement            text,                      -- Facultative / Quota Share / Surplus / XOL ...
  responsible            text,                      -- credit controller (profiles.controller_name)
  claim_amount           numeric(18,2) not null check (claim_amount >= 0),
  ri_share               numeric(9,6)  not null default 1 check (ri_share > 0 and ri_share <= 1),
  recovery_amount        numeric(18,2) not null check (recovery_amount >= 0),
  recovered_to_date      numeric(18,2) not null default 0,   -- maintained by trigger from receipts
  client_payment_status  text default 'Paid to client',
  status                 text not null default 'open'
                         check (status in ('open','partial','recovered','written_off')),
  next_follow_up         date,
  closed_at              timestamptz,
  write_off_reason       text,
  notes                  text,
  source                 text not null default 'manual',     -- manual | bulk | excel_migration
  created_by             uuid references public.profiles(id),
  created_at             timestamptz not null default now(),
  updated_by             uuid references public.profiles(id),
  updated_at             timestamptz not null default now()
);
create index if not exists recoveries_status_idx      on public.recoveries(status);
create index if not exists recoveries_responsible_idx on public.recoveries(responsible);
create index if not exists recoveries_reinsurer_idx   on public.recoveries(reinsurer);

-- ---------------------------------------------------------------------
-- 4. RECEIPTS (each recovery payment, with its proof of payment)
-- ---------------------------------------------------------------------
create table if not exists public.receipts (
  id            uuid primary key default gen_random_uuid(),
  recovery_id   uuid not null references public.recoveries(id) on delete restrict,
  amount        numeric(18,2) not null check (amount > 0),
  receipt_date  date not null,
  bank          text,
  method        text not null default 'Bank transfer'
                check (method in ('Bank transfer','Offset','Export proceeds','Cash','Other','Migrated')),
  reference     text,
  pop_path      text,          -- path inside the private 'pops' storage bucket
  pop_name      text,
  status        text not null default 'pending' check (status in ('pending','verified','rejected')),
  verified_by   uuid references public.profiles(id),
  verified_at   timestamptz,
  verify_note   text,
  created_by    uuid references public.profiles(id),
  created_at    timestamptz not null default now()
);
create index if not exists receipts_recovery_idx on public.receipts(recovery_id);

-- ---------------------------------------------------------------------
-- 5. FOLLOW-UP ACTIVITY LOG (replaces the single overwritten comment cell)
-- ---------------------------------------------------------------------
create table if not exists public.activities (
  id              uuid primary key default gen_random_uuid(),
  recovery_id     uuid not null references public.recoveries(id) on delete cascade,
  kind            text not null default 'note'
                  check (kind in ('note','call','email','meeting','promise','reassign','system')),
  note            text,
  promise_date    date,
  promise_amount  numeric(18,2),
  created_by      uuid references public.profiles(id),
  created_at      timestamptz not null default now()
);
create index if not exists activities_recovery_idx on public.activities(recovery_id);

-- ---------------------------------------------------------------------
-- 6. AUDIT LOG (every insert/update/delete, who and when)
-- ---------------------------------------------------------------------
create table if not exists public.audit_log (
  id          bigserial primary key,
  table_name  text not null,
  record_id   text,
  action      text not null,
  changed     jsonb,
  actor       uuid,
  at          timestamptz not null default now()
);
create index if not exists audit_record_idx on public.audit_log(record_id);

create or replace function public.audit_trg()
returns trigger language plpgsql security definer set search_path = public as $$
declare d jsonb := '{}'; k text; o jsonb; n jsonb;
begin
  if tg_op = 'INSERT' then
    insert into audit_log(table_name, record_id, action, changed, actor)
    values (tg_table_name, to_jsonb(new)->>'id', 'insert', to_jsonb(new), auth.uid());
    return new;
  elsif tg_op = 'DELETE' then
    insert into audit_log(table_name, record_id, action, changed, actor)
    values (tg_table_name, to_jsonb(old)->>'id', 'delete', to_jsonb(old), auth.uid());
    return old;
  end if;
  o := to_jsonb(old); n := to_jsonb(new);
  for k in select jsonb_object_keys(n) loop
    if k not in ('updated_at','updated_by') and (o->k) is distinct from (n->k) then
      d := d || jsonb_build_object(k, jsonb_build_object('from', o->k, 'to', n->k));
    end if;
  end loop;
  if d <> '{}'::jsonb then
    insert into audit_log(table_name, record_id, action, changed, actor)
    values (tg_table_name, n->>'id', 'update', d, auth.uid());
  end if;
  return new;
end $$;

drop trigger if exists audit_recoveries on public.recoveries;
create trigger audit_recoveries after insert or update or delete on public.recoveries
  for each row execute function public.audit_trg();
drop trigger if exists audit_receipts on public.receipts;
create trigger audit_receipts after insert or update or delete on public.receipts
  for each row execute function public.audit_trg();
drop trigger if exists audit_reinsurers on public.reinsurers;
create trigger audit_reinsurers after insert or update or delete on public.reinsurers
  for each row execute function public.audit_trg();
drop trigger if exists audit_profiles on public.profiles;
create trigger audit_profiles after update on public.profiles
  for each row execute function public.audit_trg();

-- ---------------------------------------------------------------------
-- 7. BUSINESS RULES
-- ---------------------------------------------------------------------
-- 7a. Status follows the money: open → partial → recovered (archived)
create or replace function public.recoveries_before_write()
returns trigger language plpgsql as $$
begin
  -- credit control may only change follow-up details, not the claim itself
  if tg_op = 'UPDATE' and auth.uid() is not null and public.my_role() = 'credit_control'
     and (new.currency, new.date_sent, new.client_name, new.claim_number, new.payee, new.reinsurer, new.responsible,
          new.claim_amount, new.ri_share, new.recovery_amount, new.status, new.write_off_reason)
         is distinct from
         (old.currency, old.date_sent, old.client_name, old.claim_number, old.payee, old.reinsurer, old.responsible,
          old.claim_amount, old.ri_share, old.recovery_amount, old.status, old.write_off_reason) then
    raise exception 'Credit control can only update follow-up details on a recovery';
  end if;
  new.updated_at := now();
  new.updated_by := coalesce(auth.uid(), new.updated_by);
  if tg_op = 'INSERT' then new.created_by := coalesce(new.created_by, auth.uid()); end if;
  if new.status <> 'written_off' then
    if new.recovery_amount > 0 and new.recovered_to_date >= new.recovery_amount - 0.005 then
      new.status := 'recovered';
    elsif new.recovered_to_date > 0 then
      new.status := 'partial';
    else
      new.status := 'open';
    end if;
  end if;
  if new.status in ('recovered','written_off') then
    new.closed_at := coalesce(new.closed_at, now());
    new.next_follow_up := null;
  else
    new.closed_at := null;
  end if;
  return new;
end $$;

drop trigger if exists recoveries_bw on public.recoveries;
create trigger recoveries_bw before insert or update on public.recoveries
  for each row execute function public.recoveries_before_write();

-- 7b. Recovered-to-date = sum of receipts that are not rejected
create or replace function public.receipts_after_write()
returns trigger language plpgsql security definer set search_path = public as $$
declare rid uuid := coalesce(new.recovery_id, old.recovery_id);
begin
  update recoveries
     set recovered_to_date = coalesce((select sum(amount) from receipts
                                        where recovery_id = rid and status <> 'rejected'), 0)
   where id = rid;
  return null;
end $$;

drop trigger if exists receipts_aw on public.receipts;
create trigger receipts_aw after insert or update or delete on public.receipts
  for each row execute function public.receipts_after_write();

create or replace function public.receipts_before_insert()
returns trigger language plpgsql as $$
begin
  new.created_by := coalesce(new.created_by, auth.uid());
  -- only finance/admin may create already-verified or migrated receipts
  if auth.uid() is not null and coalesce(public.my_role(), '') not in ('admin','finance') then
    new.status := 'pending'; new.verified_by := null; new.verified_at := null; new.verify_note := null;
    if new.method = 'Migrated' then new.method := 'Other'; end if;
  end if;
  return new;
end $$;
drop trigger if exists receipts_bi on public.receipts;
create trigger receipts_bi before insert on public.receipts
  for each row execute function public.receipts_before_insert();

create or replace function public.activities_before_insert()
returns trigger language plpgsql as $$
begin
  new.created_by := coalesce(new.created_by, auth.uid());
  return new;
end $$;
drop trigger if exists activities_bi on public.activities;
create trigger activities_bi before insert on public.activities
  for each row execute function public.activities_before_insert();

-- ---------------------------------------------------------------------
-- 8. ROW LEVEL SECURITY
-- ---------------------------------------------------------------------
alter table public.profiles      enable row level security;
alter table public.reinsurers    enable row level security;
alter table public.settings      enable row level security;
alter table public.digest_config enable row level security;   -- no policies = API can't read it
alter table public.recoveries    enable row level security;
alter table public.receipts      enable row level security;
alter table public.activities    enable row level security;
alter table public.audit_log     enable row level security;

-- read: any active signed-in user
drop policy if exists p_read on public.profiles;
create policy p_read on public.profiles for select to authenticated using (public.my_role() is not null or id = auth.uid());
drop policy if exists p_admin on public.profiles;
create policy p_admin on public.profiles for update to authenticated using (public.my_role() = 'admin');

drop policy if exists ri_read on public.reinsurers;
create policy ri_read on public.reinsurers for select to authenticated using (public.my_role() is not null);
drop policy if exists ri_ins on public.reinsurers;
create policy ri_ins on public.reinsurers for insert to authenticated
  with check (public.my_role() in ('admin','finance','claims'));
drop policy if exists ri_upd on public.reinsurers;
create policy ri_upd on public.reinsurers for update to authenticated
  using (public.my_role() in ('admin','finance'));

drop policy if exists s_read on public.settings;
create policy s_read on public.settings for select to authenticated using (public.my_role() is not null);
drop policy if exists s_upd on public.settings;
create policy s_upd on public.settings for update to authenticated using (public.my_role() = 'admin');

drop policy if exists r_read on public.recoveries;
create policy r_read on public.recoveries for select to authenticated using (public.my_role() is not null);
drop policy if exists r_ins on public.recoveries;
create policy r_ins on public.recoveries for insert to authenticated
  with check (public.my_role() in ('admin','finance','claims'));
drop policy if exists r_upd on public.recoveries;
create policy r_upd on public.recoveries for update to authenticated
  using (public.my_role() in ('admin','finance','claims','credit_control'));
drop policy if exists r_del on public.recoveries;
create policy r_del on public.recoveries for delete to authenticated using (public.my_role() = 'admin');

drop policy if exists rc_read on public.receipts;
create policy rc_read on public.receipts for select to authenticated using (public.my_role() is not null);
drop policy if exists rc_ins on public.receipts;
create policy rc_ins on public.receipts for insert to authenticated
  with check (public.my_role() in ('admin','finance','credit_control'));
drop policy if exists rc_upd on public.receipts;
create policy rc_upd on public.receipts for update to authenticated
  using (public.my_role() in ('admin','finance'));

drop policy if exists a_read on public.activities;
create policy a_read on public.activities for select to authenticated using (public.my_role() is not null);
drop policy if exists a_ins on public.activities;
create policy a_ins on public.activities for insert to authenticated
  with check (public.my_role() in ('admin','finance','claims','credit_control'));

drop policy if exists al_read on public.audit_log;
create policy al_read on public.audit_log for select to authenticated using (public.my_role() is not null);

-- ---------------------------------------------------------------------
-- 9. PROOF-OF-PAYMENT STORAGE (private bucket)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit)
values ('pops', 'pops', false, 10485760)          -- 10 MB per file
on conflict (id) do nothing;

drop policy if exists pops_read on storage.objects;
create policy pops_read on storage.objects for select to authenticated
  using (bucket_id = 'pops' and public.my_role() is not null);
drop policy if exists pops_write on storage.objects;
create policy pops_write on storage.objects for insert to authenticated
  with check (bucket_id = 'pops' and public.my_role() in ('admin','finance','credit_control'));
-- no update/delete policies: POPs cannot be overwritten or removed (audit)

-- ---------------------------------------------------------------------
-- 10. REMINDER DIGEST for Power Automate
--     POST {SUPABASE_URL}/rest/v1/rpc/reminder_digest
--     headers: apikey: <anon key>, Content-Type: application/json
--     body:    {"p_token": "<token from digest_config>"}
--     Returns one object per person who has reminders, with a ready-made
--     HTML table for the email body.
-- ---------------------------------------------------------------------
create or replace function public.reminder_items()
returns table (
  recovery_id uuid, ref text, responsible text, reason text, priority int,
  claim_number text, client_name text, reinsurer text, currency text,
  outstanding numeric, days_open int, detail text
) language sql stable security definer set search_path = public as $$
  with s as (select * from settings where id = 1),
  base as (
    select r.*,
           (r.recovery_amount - r.recovered_to_date) as outstanding,
           (current_date - r.date_sent) as days_open,
           (select max(a.created_at) from activities a where a.recovery_id = r.id and a.kind <> 'system') as last_act,
           (select max(c.created_at) from receipts c where c.recovery_id = r.id and c.method <> 'Migrated') as last_rcpt,
           (select count(*) from activities a where a.recovery_id = r.id and a.kind <> 'system') as n_act,
           (select count(*) from receipts c where c.recovery_id = r.id) as n_rcpt,
           (select a.promise_date from activities a
              where a.recovery_id = r.id and a.kind = 'promise' and a.promise_date is not null
              order by a.created_at desc limit 1) as promise_date,
           (select a.created_at from activities a
              where a.recovery_id = r.id and a.kind = 'promise' and a.promise_date is not null
              order by a.created_at desc limit 1) as promise_at
      from recoveries r
     where r.status in ('open','partial')
  ),
  flagged as (
    select b.*,
      case
        when b.responsible is null or b.responsible = '' then 'Unassigned'
        when b.promise_date is not null
             and b.promise_date + (select promise_grace_days from s) < current_date
             and (b.last_rcpt is null or b.last_rcpt < b.promise_at) then 'Promise missed'
        when b.next_follow_up is not null and b.next_follow_up <= current_date then 'Follow-up due'
        when b.n_act = 0 and b.n_rcpt = 0 and b.source <> 'excel_migration' then 'New – not yet actioned'
        when (b.next_follow_up is null or b.next_follow_up <= current_date)
             and greatest(coalesce(b.last_act, b.created_at), coalesce(b.last_rcpt, b.created_at))
                 < now() - make_interval(days => (select follow_up_days from s)) then 'No follow-up logged'
      end as reason
    from base b
  )
  select f.id, f.ref, f.responsible, f.reason,
         case f.reason when 'Unassigned' then 1 when 'Promise missed' then 2 when 'Follow-up due' then 3
                       when 'New – not yet actioned' then 4 else 5 end,
         f.claim_number, f.client_name, f.reinsurer, f.currency, f.outstanding, f.days_open,
         case f.reason
           when 'Promise missed' then 'Promised ' || to_char(f.promise_date, 'DD Mon YYYY')
           when 'Follow-up due'  then 'Due ' || to_char(f.next_follow_up, 'DD Mon YYYY')
           when 'No follow-up logged' then 'Last action ' || to_char(greatest(coalesce(f.last_act, f.created_at), coalesce(f.last_rcpt, f.created_at)), 'DD Mon YYYY')
           else '' end
    from flagged f
   where f.reason is not null
   order by 5, f.outstanding desc;
$$;
revoke all on function public.reminder_items() from public, anon;
grant execute on function public.reminder_items() to authenticated;

create or replace function public.reminder_digest(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare result jsonb;
begin
  if p_token is null or p_token <> (select token from digest_config where id = 1) then
    raise exception 'invalid token';
  end if;

  with items as (select * from reminder_items()),
  recipients as (
    -- controllers get their own items
    select p.id, p.email, p.full_name, p.controller_name as who
      from profiles p
     where p.active and p.email_reminders and p.role = 'credit_control' and p.controller_name is not null
  ),
  per_person as (
    select rc.email, rc.full_name,
           count(i.*) as n,
           count(*) filter (where i.priority <= 3) as n_urgent,
           '<table style="border-collapse:collapse;font-family:Segoe UI,Arial,sans-serif;font-size:13px">'
           || '<tr style="background:#0f3d3e;color:#fff">'
           || '<th style="padding:6px 8px;text-align:left">Ref</th><th style="padding:6px 8px;text-align:left">Reason</th>'
           || '<th style="padding:6px 8px;text-align:left">Claim</th><th style="padding:6px 8px;text-align:left">Client</th>'
           || '<th style="padding:6px 8px;text-align:left">Reinsurer</th><th style="padding:6px 8px;text-align:right">Outstanding</th>'
           || '<th style="padding:6px 8px;text-align:right">Days</th></tr>'
           || string_agg(
                '<tr style="border-bottom:1px solid #e5e7eb"><td style="padding:6px 8px">' || i.ref
                || '</td><td style="padding:6px 8px"><b>' || i.reason || '</b>' || case when i.detail <> '' then '<br><span style="color:#6b7280">' || i.detail || '</span>' else '' end
                || '</td><td style="padding:6px 8px">' || coalesce(i.claim_number,'')
                || '</td><td style="padding:6px 8px">' || coalesce(i.client_name,'')
                || '</td><td style="padding:6px 8px">' || coalesce(i.reinsurer,'')
                || '</td><td style="padding:6px 8px;text-align:right">' || i.currency || ' ' || to_char(i.outstanding, 'FM999,999,999,990.00')
                || '</td><td style="padding:6px 8px;text-align:right">' || i.days_open || '</td></tr>',
                '' order by i.priority, i.outstanding desc)
           || '</table>' as html
      from recipients rc
      join items i on i.responsible = rc.who
     group by rc.email, rc.full_name
    union all
    -- admins & finance get the unassigned queue
    select p.email, p.full_name, count(i.*), count(i.*),
           '<p>The following recoveries have no credit controller assigned:</p><ul>'
           || string_agg('<li>' || i.ref || ' — ' || coalesce(i.claim_number,'') || ' — ' || coalesce(i.reinsurer,'')
                         || ' — ' || i.currency || ' ' || to_char(i.outstanding, 'FM999,999,999,990.00') || '</li>', '')
           || '</ul>'
      from profiles p
      cross join items i
     where p.active and p.email_reminders and p.role in ('admin','finance') and i.reason = 'Unassigned'
     group by p.email, p.full_name
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'email', email, 'name', full_name, 'count', n, 'urgent', n_urgent,
           'subject', 'Recoveries follow-up: ' || n || ' item(s) need your attention',
           'html', html)), '[]'::jsonb)
    into result
    from per_person where n > 0;
  return result;
end $$;
revoke all on function public.reminder_digest(text) from public;
grant execute on function public.reminder_digest(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 11. LIVE UPDATES (screens refresh when a colleague saves something)
-- ---------------------------------------------------------------------
do $$ begin
  alter publication supabase_realtime add table public.recoveries, public.receipts, public.activities;
exception when others then null; end $$;

-- To see the token for Power Automate (run in SQL editor as owner):
--   select token from public.digest_config;
