-- iMessages Stats: Paid Plans (Free vs Pro) + RLS
-- Run in Supabase SQL Editor.
--
-- Goals:
-- - Track a user's plan in `public.user_entitlements`.
-- - Users can read their own plan, but cannot set themselves to Pro.
-- - Admins (profiles.is_admin = true) can read/write any user's entitlements.
-- - Pro (or Admin) required to write to cloud-sync tables (`message_reports`, `user_contacts`).
-- - Avoid RLS recursion issues by using SECURITY DEFINER helpers with row_security = off.

begin;

-- -----------------------------------------------------------------------------
-- 1) Admin helper (safe, non-conflicting)
-- -----------------------------------------------------------------------------
-- IMPORTANT:
-- Your project already has a `public.is_admin(uuid)` function (and policies depend on it).
-- Some versions include parameter defaults, and Postgres won't let CREATE OR REPLACE remove them.
-- To avoid breaking existing policies, we define *new* helper functions with unique names and
-- use them in the new paid-plan policies below.

create or replace function public.imsg_is_admin_uid(p_uid uuid)
returns boolean
language sql
security definer
set search_path = public
set row_security = off
as $$
  select coalesce((select p.is_admin from public.profiles p where p.id = p_uid), false);
$$;

create or replace function public.imsg_is_admin()
returns boolean
language sql
security definer
set search_path = public
set row_security = off
as $$
  select public.imsg_is_admin_uid(auth.uid());
$$;

-- -----------------------------------------------------------------------------
-- 2) Entitlements table
-- -----------------------------------------------------------------------------
create table if not exists public.user_entitlements (
  user_id uuid primary key references auth.users(id) on delete cascade,
  plan text not null default 'free' check (plan in ('free','pro')),
  updated_at timestamptz not null default now()
);

create or replace function public.tg_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists user_entitlements_touch_updated_at on public.user_entitlements;
create trigger user_entitlements_touch_updated_at
before update on public.user_entitlements
for each row execute function public.tg_touch_updated_at();

alter table public.user_entitlements enable row level security;

-- Remove all existing policies on user_entitlements (policies are OR'ed, so old
-- permissive ones would break paid gating).
do $$
declare r record;
begin
  for r in
    select policyname from pg_policies where schemaname = 'public' and tablename = 'user_entitlements'
  loop
    execute format('drop policy if exists %I on public.user_entitlements', r.policyname);
  end loop;
end $$;

-- Users can read their own plan. Admins can read all.
create policy user_entitlements_read
on public.user_entitlements
for select
to authenticated
using (user_id = auth.uid() or public.imsg_is_admin());

-- Users can insert their own row, but only as Free (supports first-login bootstrap).
create policy user_entitlements_insert_own_free
on public.user_entitlements
for insert
to authenticated
with check (user_id = auth.uid() and plan = 'free');

-- Admins can do anything (insert/update/delete/select).
create policy user_entitlements_admin_all
on public.user_entitlements
for all
to authenticated
using (public.imsg_is_admin())
with check (public.imsg_is_admin());

-- -----------------------------------------------------------------------------
-- 3) Ensure an entitlements row exists for every profile (new + existing)
-- -----------------------------------------------------------------------------
create or replace function public.tg_profiles_ensure_entitlements()
returns trigger
language plpgsql
security definer
set search_path = public
set row_security = off
as $$
begin
  insert into public.user_entitlements(user_id, plan)
  values (new.id, 'free')
  on conflict (user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists profiles_ensure_entitlements on public.profiles;
create trigger profiles_ensure_entitlements
after insert on public.profiles
for each row execute function public.tg_profiles_ensure_entitlements();

insert into public.user_entitlements(user_id, plan)
select p.id, 'free'
from public.profiles p
on conflict (user_id) do nothing;

-- -----------------------------------------------------------------------------
-- 4) Pro access helper
-- -----------------------------------------------------------------------------
-- Keep any existing `has_pro_access` helpers intact (if you have them) to avoid
-- breaking other policies. We'll use `imsg_has_pro_access` for new policies.

create function public.imsg_has_pro_access(p_uid uuid)
returns boolean
language sql
security definer
set search_path = public
set row_security = off
as $$
  select
    public.imsg_is_admin_uid(p_uid)
    or exists (
      select 1
      from public.user_entitlements ue
      where ue.user_id = p_uid
        and ue.plan = 'pro'
    );
$$;

create function public.imsg_has_pro_access()
returns boolean
language sql
security definer
set search_path = public
set row_security = off
as $$
  select public.imsg_has_pro_access(auth.uid());
$$;

-- -----------------------------------------------------------------------------
-- 5) Enforce Pro on cloud sync tables (message_reports, user_contacts)
-- -----------------------------------------------------------------------------

-- message_reports
alter table public.message_reports enable row level security;
do $$
declare r record;
begin
  for r in
    select policyname from pg_policies where schemaname = 'public' and tablename = 'message_reports'
  loop
    execute format('drop policy if exists %I on public.message_reports', r.policyname);
  end loop;
end $$;

create policy message_reports_read_own_or_admin
on public.message_reports
for select
to authenticated
using (user_id = auth.uid() or public.imsg_is_admin());

create policy message_reports_insert_pro
on public.message_reports
for insert
to authenticated
with check (user_id = auth.uid() and public.imsg_has_pro_access(auth.uid()));

-- user_contacts
alter table public.user_contacts enable row level security;
do $$
declare r record;
begin
  for r in
    select policyname from pg_policies where schemaname = 'public' and tablename = 'user_contacts'
  loop
    execute format('drop policy if exists %I on public.user_contacts', r.policyname);
  end loop;
end $$;

create policy user_contacts_read_own_or_admin
on public.user_contacts
for select
to authenticated
using (owner_user_id = auth.uid() or public.imsg_is_admin());

create policy user_contacts_insert_pro
on public.user_contacts
for insert
to authenticated
with check (owner_user_id = auth.uid() and public.imsg_has_pro_access(auth.uid()));

commit;
