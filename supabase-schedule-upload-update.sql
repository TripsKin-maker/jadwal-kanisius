-- ================================================================
-- UPDATE: MASTER ADMIN + PDF/IMAGE SCHEDULE UPLOAD
-- Run this file once AFTER supabase-setup.sql.
-- Default master account: adminPusat / AdminPusat!
-- ================================================================

create extension if not exists pgcrypto;

-- Add the master_admin role to the existing account table.
alter table public.kk_accounts
  drop constraint if exists kk_accounts_role_check;
alter table public.kk_accounts
  add constraint kk_accounts_role_check
  check (role in ('student','admin','master_admin'));

-- One central administrator. X-1 is only a required placeholder class; the
-- master account can publish schedules for all 24 classes.
insert into public.kk_accounts(class_id,username,password_hash,display_name,role)
select c.id,'adminPusat',
       crypt('AdminPusat!',gen_salt('bf',8)),
       'Admin Pusat Jadwal','master_admin'
from public.classes c
where c.name='X-1'
on conflict (username) do nothing;

create table if not exists public.kk_schedule_versions (
  id uuid primary key default gen_random_uuid(),
  uploaded_by uuid not null references public.kk_accounts(id) on delete restrict,
  file_name text not null,
  file_type text not null,
  ocr_text text not null default '',
  is_active boolean not null default false,
  created_at timestamptz not null default now(),
  published_at timestamptz not null default now()
);
create unique index if not exists kk_one_active_schedule_idx
  on public.kk_schedule_versions(is_active) where is_active=true;

create table if not exists public.kk_schedule_entries (
  id uuid primary key default gen_random_uuid(),
  version_id uuid not null references public.kk_schedule_versions(id) on delete cascade,
  class_name text not null,
  day_name text not null check (day_name in ('Senin','Selasa','Rabu','Kamis','Jumat')),
  period smallint not null check (period between 1 and 12),
  time_range text not null,
  subject_code text not null,
  created_at timestamptz not null default now(),
  unique(version_id,class_name,day_name,period),
  foreign key(class_name) references public.classes(name) on update cascade on delete restrict
);
create index if not exists kk_schedule_entries_version_idx on public.kk_schedule_entries(version_id);

alter table public.kk_schedule_versions enable row level security;
alter table public.kk_schedule_entries enable row level security;
revoke all on public.kk_schedule_versions from anon, authenticated;
revoke all on public.kk_schedule_entries from anon, authenticated;

-- All logged-in accounts may read the currently published schedule.
create or replace function public.kk_list_schedule(p_session_token text)
returns table(
  version_id uuid,
  class_name text,
  day_name text,
  period smallint,
  time_range text,
  subject_code text,
  file_name text,
  published_at timestamptz
)
language plpgsql
security definer
set search_path=public,extensions,private
as $$
declare
  viewer public.kk_accounts%rowtype;
begin
  viewer := private.kk_account_for_token(p_session_token);
  return query
  select e.version_id,e.class_name,e.day_name,e.period,e.time_range,
         e.subject_code,v.file_name,v.published_at
  from public.kk_schedule_versions v
  join public.kk_schedule_entries e on e.version_id=v.id
  where v.is_active=true
  order by e.class_name,e.day_name,e.period;
end;
$$;

create or replace function public.kk_schedule_status(p_session_token text)
returns table(
  version_id uuid,
  file_name text,
  file_type text,
  published_at timestamptz,
  entry_count bigint
)
language plpgsql
security definer
set search_path=public,extensions,private
as $$
declare
  viewer public.kk_accounts%rowtype;
begin
  viewer := private.kk_account_for_token(p_session_token);
  return query
  select v.id,v.file_name,v.file_type,v.published_at,count(e.id)
  from public.kk_schedule_versions v
  left join public.kk_schedule_entries e on e.version_id=v.id
  where v.is_active=true
  group by v.id,v.file_name,v.file_type,v.published_at;
end;
$$;

-- Publish a reviewed OCR draft. Only adminPusat/master_admin can call this.
create or replace function public.kk_publish_schedule(
  p_session_token text,
  p_file_name text,
  p_file_type text,
  p_ocr_text text,
  p_entries jsonb
)
returns uuid
language plpgsql
security definer
set search_path=public,extensions,private
as $$
declare
  viewer public.kk_accounts%rowtype;
  new_version uuid;
  item jsonb;
  v_class text;
  v_day text;
  v_period integer;
  v_time text;
  v_subject text;
  total integer;
begin
  viewer := private.kk_account_for_token(p_session_token);
  if viewer.role <> 'master_admin' then
    raise exception 'Publikasi jadwal khusus admin pusat.';
  end if;
  if jsonb_typeof(p_entries) <> 'array' then
    raise exception 'Data jadwal harus berupa array.';
  end if;
  total := jsonb_array_length(p_entries);
  if total < 1 or total > 2000 then
    raise exception 'Jumlah baris jadwal harus antara 1 dan 2000.';
  end if;

  update public.kk_schedule_versions set is_active=false where is_active=true;
  insert into public.kk_schedule_versions(
    uploaded_by,file_name,file_type,ocr_text,is_active
  ) values (
    viewer.id,left(coalesce(nullif(trim(p_file_name),''),'jadwal'),240),
    left(coalesce(p_file_type,'unknown'),100),left(coalesce(p_ocr_text,''),500000),true
  ) returning id into new_version;

  for item in select value from jsonb_array_elements(p_entries)
  loop
    v_class := upper(trim(item->>'class_name'));
    v_day := initcap(lower(trim(item->>'day_name')));
    v_period := (item->>'period')::integer;
    v_time := trim(item->>'time_range');
    v_subject := trim(item->>'subject_code');

    if not exists(select 1 from public.classes c where c.name=v_class) then
      raise exception 'Kelas tidak valid: %',v_class;
    end if;
    if v_day not in ('Senin','Selasa','Rabu','Kamis','Jumat') then
      raise exception 'Hari tidak valid: %',v_day;
    end if;
    if v_period < 1 or v_period > 12 then
      raise exception 'Jam ke tidak valid: %',v_period;
    end if;
    if v_time is null or v_time='' or v_subject is null or v_subject='' then
      raise exception 'Waktu dan mata pelajaran tidak boleh kosong.';
    end if;

    insert into public.kk_schedule_entries(
      version_id,class_name,day_name,period,time_range,subject_code
    ) values (
      new_version,v_class,v_day,v_period,left(v_time,30),left(v_subject,60)
    );
  end loop;
  return new_version;
end;
$$;

revoke all on function public.kk_list_schedule(text) from public;
revoke all on function public.kk_schedule_status(text) from public;
revoke all on function public.kk_publish_schedule(text,text,text,text,jsonb) from public;
grant execute on function public.kk_list_schedule(text) to anon,authenticated;
grant execute on function public.kk_schedule_status(text) to anon,authenticated;
grant execute on function public.kk_publish_schedule(text,text,text,text,jsonb) to anon,authenticated;

-- Verification: should show one master_admin account.
select role,count(*) as account_count
from public.kk_accounts
group by role
order by role;
