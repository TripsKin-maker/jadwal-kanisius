-- Jadwal Kanisius: shared, multi-device storage
-- Run this entire file once in Supabase Dashboard > SQL Editor.

create extension if not exists pgcrypto;

create table if not exists public.classes (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique,
  display_name text not null,
  role text not null default 'student' check (role in ('student','admin')),
  class_id uuid not null references public.classes(id) on delete restrict,
  created_at timestamptz not null default now()
);

create table if not exists public.assignments (
  id uuid primary key default gen_random_uuid(),
  class_id uuid not null references public.classes(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 300),
  subject text not null default '',
  description text not null default '',
  category text not null default 'task' check (category in ('task','exam')),
  due_date date,
  recurrence text not null default 'none' check (recurrence in ('none','weekly','biweekly')),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.assignment_completions (
  assignment_id uuid not null references public.assignments(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  completed_at timestamptz not null default now(),
  primary key (assignment_id, user_id)
);

create index if not exists assignments_class_id_idx on public.assignments(class_id);
create index if not exists completions_user_id_idx on public.assignment_completions(user_id);
create index if not exists profiles_class_id_idx on public.profiles(class_id);

insert into public.classes(name)
select tier || '-' || n
from unnest(array['X','XI','XII']) as tier
cross join generate_series(1,8) as n
on conflict (name) do nothing;

-- Create a profile automatically from the class chosen on the sign-up screen.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  selected_class_id uuid;
  selected_class_name text;
  chosen_name text;
begin
  selected_class_name := new.raw_user_meta_data ->> 'class_name';
  chosen_name := coalesce(nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''), split_part(new.email, '@', 1));
  select id into selected_class_id from public.classes where name = selected_class_name;

  if selected_class_id is not null then
    insert into public.profiles(user_id, username, display_name, role, class_id)
    values (new.id, lower(new.email), chosen_name, 'student', selected_class_id)
    on conflict (user_id) do update set
      username = excluded.username,
      display_name = excluded.display_name,
      class_id = excluded.class_id;
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert or update of raw_user_meta_data on auth.users
for each row execute function public.handle_new_user();

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists assignments_touch_updated_at on public.assignments;
create trigger assignments_touch_updated_at
before update on public.assignments
for each row execute function public.touch_updated_at();

alter table public.classes enable row level security;
alter table public.profiles enable row level security;
alter table public.assignments enable row level security;
alter table public.assignment_completions enable row level security;

-- Policies: authenticated users can see class names and their own profile.
drop policy if exists classes_read_authenticated on public.classes;
create policy classes_read_authenticated on public.classes
for select to authenticated using (true);

drop policy if exists profiles_read_own on public.profiles;
create policy profiles_read_own on public.profiles
for select to authenticated using (user_id = auth.uid());

drop policy if exists profiles_insert_own on public.profiles;
create policy profiles_insert_own on public.profiles
for insert to authenticated
with check (user_id = auth.uid() and role = 'student');

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
for update to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

-- Every member of a class can collaborate on that class's assignment list.
drop policy if exists assignments_read_same_class on public.assignments;
create policy assignments_read_same_class on public.assignments
for select to authenticated
using (class_id = (select p.class_id from public.profiles p where p.user_id = auth.uid()));

drop policy if exists assignments_insert_same_class on public.assignments;
create policy assignments_insert_same_class on public.assignments
for insert to authenticated
with check (
  class_id = (select p.class_id from public.profiles p where p.user_id = auth.uid())
  and created_by = auth.uid()
);

drop policy if exists assignments_update_same_class on public.assignments;
create policy assignments_update_same_class on public.assignments
for update to authenticated
using (class_id = (select p.class_id from public.profiles p where p.user_id = auth.uid()))
with check (class_id = (select p.class_id from public.profiles p where p.user_id = auth.uid()));

drop policy if exists assignments_delete_same_class on public.assignments;
create policy assignments_delete_same_class on public.assignments
for delete to authenticated
using (class_id = (select p.class_id from public.profiles p where p.user_id = auth.uid()));

-- Completion checkmarks are private per account, while the assignment itself is shared.
drop policy if exists completions_read_own on public.assignment_completions;
create policy completions_read_own on public.assignment_completions
for select to authenticated using (user_id = auth.uid());

drop policy if exists completions_insert_own on public.assignment_completions;
create policy completions_insert_own on public.assignment_completions
for insert to authenticated
with check (
  user_id = auth.uid()
  and exists (
    select 1 from public.assignments a
    join public.profiles p on p.class_id = a.class_id
    where a.id = assignment_id and p.user_id = auth.uid()
  )
);

drop policy if exists completions_update_own on public.assignment_completions;
create policy completions_update_own on public.assignment_completions
for update to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

drop policy if exists completions_delete_own on public.assignment_completions;
create policy completions_delete_own on public.assignment_completions
for delete to authenticated using (user_id = auth.uid());

grant usage on schema public to authenticated;
grant select on public.classes to authenticated;
grant select, insert, update on public.profiles to authenticated;
grant select, insert, update, delete on public.assignments to authenticated;
grant select, insert, update, delete on public.assignment_completions to authenticated;

-- Realtime pushes a friend's change to an already-open page.
alter table public.assignments replica identity full;
alter table public.assignment_completions replica identity full;
do $$
begin
  alter publication supabase_realtime add table public.assignments;
exception when duplicate_object then null;
end $$;
do $$
begin
  alter publication supabase_realtime add table public.assignment_completions;
exception when duplicate_object then null;
end $$;
