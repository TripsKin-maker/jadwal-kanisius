-- ================================================================
-- JADWAL KANISIUS — PRE-CREATED ADMIN/STUDENT ACCOUNTS
-- Run this entire file once in Supabase Dashboard > SQL Editor.
--
-- Creates 24 classes: X-1..X-8, XI-1..XI-8, XII-1..XII-8
-- Creates per class: 1 admin + 40 students (984 accounts total)
-- Examples for X-1:
--   adminX1       / AdminX1!
--   X1-siswa01    / Siswa01!X1
--   ...
--   X1-siswa40    / Siswa40!X1
-- ================================================================

create extension if not exists pgcrypto;
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists public.classes (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  created_at timestamptz not null default now()
);

insert into public.classes(name)
select tier || '-' || n
from unnest(array['X','XI','XII']) as tier
cross join generate_series(1,8) as n
on conflict (name) do nothing;

create table if not exists public.kk_accounts (
  id uuid primary key default gen_random_uuid(),
  class_id uuid not null references public.classes(id) on delete cascade,
  username text not null unique,
  password_hash text not null,
  display_name text not null,
  role text not null check (role in ('student','admin')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists kk_accounts_username_lower_idx on public.kk_accounts(lower(username));
create index if not exists kk_accounts_class_idx on public.kk_accounts(class_id);

create table if not exists public.kk_sessions (
  token_hash text primary key,
  account_id uuid not null references public.kk_accounts(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  last_seen_at timestamptz not null default now()
);
create index if not exists kk_sessions_account_idx on public.kk_sessions(account_id);
create index if not exists kk_sessions_expiry_idx on public.kk_sessions(expires_at);

create table if not exists public.kk_shared_assignments (
  id uuid primary key default gen_random_uuid(),
  class_id uuid not null references public.classes(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 300),
  subject text not null default '',
  description text not null default '',
  category text not null default 'task' check (category in ('task','exam')),
  due_date date,
  recurrence text not null default 'none' check (recurrence in ('none','weekly','biweekly')),
  created_by uuid not null references public.kk_accounts(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists kk_shared_assignments_class_idx on public.kk_shared_assignments(class_id);

create table if not exists public.kk_student_completions (
  assignment_id uuid not null references public.kk_shared_assignments(id) on delete cascade,
  account_id uuid not null references public.kk_accounts(id) on delete cascade,
  completed_at timestamptz not null default now(),
  primary key (assignment_id, account_id)
);
create index if not exists kk_student_completions_account_idx on public.kk_student_completions(account_id);

create or replace function public.kk_touch_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists kk_accounts_touch_updated_at on public.kk_accounts;
create trigger kk_accounts_touch_updated_at
before update on public.kk_accounts
for each row execute function public.kk_touch_updated_at();

drop trigger if exists kk_assignments_touch_updated_at on public.kk_shared_assignments;
create trigger kk_assignments_touch_updated_at
before update on public.kk_shared_assignments
for each row execute function public.kk_touch_updated_at();

-- Create all default administrators. Existing accounts are not reset when
-- this setup file is run again, so changed passwords remain changed.
insert into public.kk_accounts(class_id, username, password_hash, display_name, role)
select
  c.id,
  'admin' || replace(c.name,'-',''),
  crypt('Admin' || replace(c.name,'-','') || '!', gen_salt('bf',8)),
  'Admin Kelas ' || c.name,
  'admin'
from public.classes c
where c.name ~ '^(X|XI|XII)-[1-8]$'
on conflict (username) do nothing;

-- Create siswa01 through siswa40 for every class.
insert into public.kk_accounts(class_id, username, password_hash, display_name, role)
select
  c.id,
  replace(c.name,'-','') || '-siswa' || lpad(n::text,2,'0'),
  crypt('Siswa' || lpad(n::text,2,'0') || '!' || replace(c.name,'-',''), gen_salt('bf',8)),
  'Siswa ' || lpad(n::text,2,'0'),
  'student'
from public.classes c
cross join generate_series(1,40) n
where c.name ~ '^(X|XI|XII)-[1-8]$'
on conflict (username) do nothing;

-- No table is readable directly from a browser. The page can only use the
-- checked SECURITY DEFINER functions below.
alter table public.kk_accounts enable row level security;
alter table public.kk_sessions enable row level security;
alter table public.kk_shared_assignments enable row level security;
alter table public.kk_student_completions enable row level security;
revoke all on public.kk_accounts from anon, authenticated;
revoke all on public.kk_sessions from anon, authenticated;
revoke all on public.kk_shared_assignments from anon, authenticated;
revoke all on public.kk_student_completions from anon, authenticated;

-- Internal session lookup. This function is in a non-exposed schema.
create or replace function private.kk_account_for_token(p_token text)
returns public.kk_accounts
language plpgsql
security definer
set search_path = public, extensions, private
as $$
declare
  result public.kk_accounts%rowtype;
begin
  if coalesce(length(p_token),0) < 32 then
    raise exception 'Sesi tidak valid atau kedaluwarsa.';
  end if;
  select a.* into result
  from public.kk_sessions s
  join public.kk_accounts a on a.id = s.account_id
  where s.token_hash = encode(digest(p_token,'sha256'),'hex')
    and s.expires_at > now()
    and a.active = true;
  if result.id is null then
    raise exception 'Sesi tidak valid atau kedaluwarsa.';
  end if;
  return result;
end;
$$;
revoke all on function private.kk_account_for_token(text) from public, anon, authenticated;

-- Login returns a random 30-day session token. Password verification happens
-- only inside Postgres; password hashes are never sent to the browser.
create or replace function public.kk_login(p_username text, p_password text)
returns table(
  session_token text,
  account_id uuid,
  username text,
  display_name text,
  role text,
  class_name text,
  expires_at timestamptz
)
language plpgsql
security definer
set search_path = public, extensions, private
as $$
declare
  account_row public.kk_accounts%rowtype;
  raw_token text;
  expiry timestamptz := now() + interval '30 days';
begin
  delete from public.kk_sessions where kk_sessions.expires_at <= now();
  select a.* into account_row
  from public.kk_accounts a
  where lower(a.username) = lower(trim(p_username)) and a.active = true;
  if account_row.id is null then
    raise exception 'Username atau password salah.';
  end if;
  if account_row.password_hash <> crypt(p_password, account_row.password_hash) then
    raise exception 'Username atau password salah.';
  end if;

  raw_token := encode(gen_random_bytes(32),'hex');
  insert into public.kk_sessions(token_hash, account_id, expires_at)
  values (encode(digest(raw_token,'sha256'),'hex'), account_row.id, expiry);

  -- Keep at most 10 active sessions per account.
  delete from public.kk_sessions s
  where s.account_id = account_row.id
    and s.token_hash not in (
      select s2.token_hash from public.kk_sessions s2
      where s2.account_id = account_row.id
      order by s2.created_at desc limit 10
    );

  return query
  select raw_token, account_row.id, account_row.username,
         account_row.display_name, account_row.role, c.name, expiry
  from public.classes c where c.id = account_row.class_id;
end;
$$;

create or replace function public.kk_session_me(p_session_token text)
returns table(
  account_id uuid,
  username text,
  display_name text,
  role text,
  class_name text,
  expires_at timestamptz
)
language plpgsql
security definer
set search_path = public, extensions, private
as $$
declare
  account_row public.kk_accounts%rowtype;
begin
  account_row := private.kk_account_for_token(p_session_token);
  update public.kk_sessions s set last_seen_at=now()
  where s.token_hash=encode(digest(p_session_token,'sha256'),'hex');
  return query
  select account_row.id, account_row.username, account_row.display_name,
         account_row.role, c.name, s.expires_at
  from public.classes c
  join public.kk_sessions s on s.account_id=account_row.id
  where c.id=account_row.class_id
    and s.token_hash=encode(digest(p_session_token,'sha256'),'hex');
end;
$$;

create or replace function public.kk_logout(p_session_token text)
returns void
language sql
security definer
set search_path = public, extensions
as $$
  delete from public.kk_sessions
  where token_hash=encode(digest(p_session_token,'sha256'),'hex');
$$;

create or replace function public.kk_change_password(
  p_session_token text,
  p_old_password text,
  p_new_password text
)
returns void
language plpgsql
security definer
set search_path = public, extensions, private
as $$
declare
  account_row public.kk_accounts%rowtype;
begin
  account_row := private.kk_account_for_token(p_session_token);
  if account_row.password_hash <> crypt(p_old_password, account_row.password_hash) then
    raise exception 'Password lama salah.';
  end if;
  if length(p_new_password) < 6 then
    raise exception 'Password baru minimal 6 karakter.';
  end if;
  update public.kk_accounts
  set password_hash=crypt(p_new_password,gen_salt('bf',8))
  where id=account_row.id;
end;
$$;

create or replace function public.kk_list_assignments(p_session_token text)
returns table(
  id uuid,
  class_id uuid,
  title text,
  subject text,
  description text,
  category text,
  due_date date,
  recurrence text,
  created_at timestamptz,
  updated_at timestamptz,
  done boolean
)
language plpgsql
security definer
set search_path = public, extensions, private
as $$
declare
  viewer public.kk_accounts%rowtype;
begin
  viewer := private.kk_account_for_token(p_session_token);
  return query
  select a.id,a.class_id,a.title,a.subject,a.description,a.category,
         a.due_date,a.recurrence,a.created_at,a.updated_at,
         case when viewer.role='student' then exists(
           select 1 from public.kk_student_completions sc
           where sc.assignment_id=a.id and sc.account_id=viewer.id
         ) else false end
  from public.kk_shared_assignments a
  where a.class_id=viewer.class_id
  order by a.created_at asc;
end;
$$;

create or replace function public.kk_create_assignment(
  p_session_token text,
  p_title text,
  p_subject text,
  p_description text,
  p_category text,
  p_due_date date,
  p_recurrence text
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions, private
as $$
declare
  viewer public.kk_accounts%rowtype;
  new_id uuid;
begin
  viewer := private.kk_account_for_token(p_session_token);
  if viewer.role <> 'admin' then raise exception 'Aksi ini khusus admin kelas.'; end if;
  if nullif(trim(p_title),'') is null then raise exception 'Nama tugas tidak boleh kosong.'; end if;
  insert into public.kk_shared_assignments(
    class_id,title,subject,description,category,due_date,recurrence,created_by
  ) values (
    viewer.class_id,trim(p_title),coalesce(trim(p_subject),''),coalesce(trim(p_description),''),
    case when p_category='exam' then 'exam' else 'task' end,p_due_date,
    case when p_recurrence in ('weekly','biweekly') then p_recurrence else 'none' end,viewer.id
  ) returning id into new_id;
  return new_id;
end;
$$;

create or replace function public.kk_update_assignment(
  p_session_token text,
  p_assignment_id uuid,
  p_title text,
  p_subject text,
  p_description text,
  p_category text,
  p_due_date date,
  p_recurrence text
)
returns void
language plpgsql
security definer
set search_path = public, extensions, private
as $$
declare
  viewer public.kk_accounts%rowtype;
begin
  viewer := private.kk_account_for_token(p_session_token);
  if viewer.role <> 'admin' then raise exception 'Aksi ini khusus admin kelas.'; end if;
  if nullif(trim(p_title),'') is null then raise exception 'Nama tugas tidak boleh kosong.'; end if;
  update public.kk_shared_assignments set
    title=trim(p_title),subject=coalesce(trim(p_subject),''),description=coalesce(trim(p_description),''),
    category=case when p_category='exam' then 'exam' else 'task' end,due_date=p_due_date,
    recurrence=case when p_recurrence in ('weekly','biweekly') then p_recurrence else 'none' end
  where id=p_assignment_id and class_id=viewer.class_id;
  if not found then raise exception 'Tugas tidak ditemukan di kelas ini.'; end if;
end;
$$;

create or replace function public.kk_delete_assignment(
  p_session_token text,
  p_assignment_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, extensions, private
as $$
declare
  viewer public.kk_accounts%rowtype;
begin
  viewer := private.kk_account_for_token(p_session_token);
  if viewer.role <> 'admin' then raise exception 'Aksi ini khusus admin kelas.'; end if;
  delete from public.kk_shared_assignments
  where id=p_assignment_id and class_id=viewer.class_id;
  if not found then raise exception 'Tugas tidak ditemukan di kelas ini.'; end if;
end;
$$;

create or replace function public.kk_set_completion(
  p_session_token text,
  p_assignment_id uuid,
  p_done boolean
)
returns void
language plpgsql
security definer
set search_path = public, extensions, private
as $$
declare
  viewer public.kk_accounts%rowtype;
begin
  viewer := private.kk_account_for_token(p_session_token);
  if viewer.role <> 'student' then raise exception 'Tanda selesai khusus siswa.'; end if;
  if not exists(
    select 1 from public.kk_shared_assignments a
    where a.id=p_assignment_id and a.class_id=viewer.class_id
  ) then raise exception 'Tugas tidak ditemukan di kelas ini.'; end if;
  if p_done then
    insert into public.kk_student_completions(assignment_id,account_id)
    values(p_assignment_id,viewer.id)
    on conflict(assignment_id,account_id)
    do update set completed_at=now();
  else
    delete from public.kk_student_completions
    where assignment_id=p_assignment_id and account_id=viewer.id;
  end if;
end;
$$;

create or replace function public.kk_complete_all(p_session_token text)
returns void
language plpgsql
security definer
set search_path = public, extensions, private
as $$
declare
  viewer public.kk_accounts%rowtype;
begin
  viewer := private.kk_account_for_token(p_session_token);
  if viewer.role <> 'student' then raise exception 'Tanda selesai khusus siswa.'; end if;
  insert into public.kk_student_completions(assignment_id,account_id)
  select a.id,viewer.id from public.kk_shared_assignments a
  where a.class_id=viewer.class_id
  on conflict(assignment_id,account_id) do update set completed_at=now();
end;
$$;

create or replace function public.kk_reset_completions(p_session_token text)
returns void
language plpgsql
security definer
set search_path = public, extensions, private
as $$
declare
  viewer public.kk_accounts%rowtype;
begin
  viewer := private.kk_account_for_token(p_session_token);
  if viewer.role <> 'student' then raise exception 'Tanda selesai khusus siswa.'; end if;
  delete from public.kk_student_completions where account_id=viewer.id;
end;
$$;

-- Only the RPC functions are callable with the public browser key.
revoke all on function public.kk_login(text,text) from public;
revoke all on function public.kk_session_me(text) from public;
revoke all on function public.kk_logout(text) from public;
revoke all on function public.kk_change_password(text,text,text) from public;
revoke all on function public.kk_list_assignments(text) from public;
revoke all on function public.kk_create_assignment(text,text,text,text,text,date,text) from public;
revoke all on function public.kk_update_assignment(text,uuid,text,text,text,text,date,text) from public;
revoke all on function public.kk_delete_assignment(text,uuid) from public;
revoke all on function public.kk_set_completion(text,uuid,boolean) from public;
revoke all on function public.kk_complete_all(text) from public;
revoke all on function public.kk_reset_completions(text) from public;

grant execute on function public.kk_login(text,text) to anon, authenticated;
grant execute on function public.kk_session_me(text) to anon, authenticated;
grant execute on function public.kk_logout(text) to anon, authenticated;
grant execute on function public.kk_change_password(text,text,text) to anon, authenticated;
grant execute on function public.kk_list_assignments(text) to anon, authenticated;
grant execute on function public.kk_create_assignment(text,text,text,text,text,date,text) to anon, authenticated;
grant execute on function public.kk_update_assignment(text,uuid,text,text,text,text,date,text) to anon, authenticated;
grant execute on function public.kk_delete_assignment(text,uuid) to anon, authenticated;
grant execute on function public.kk_set_completion(text,uuid,boolean) to anon, authenticated;
grant execute on function public.kk_complete_all(text) to anon, authenticated;
grant execute on function public.kk_reset_completions(text) to anon, authenticated;

-- Final verification: should return 24 admins + 960 students = 984 accounts.
select role,count(*) as account_count from public.kk_accounts group by role order by role;
