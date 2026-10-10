-- Stock Inventory – database schema for Supabase.
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
--
-- Two kinds of people:
--   * Admins  – sign in with email + password (Supabase Auth) and listed in user_roles.
--   * Staff   – sign in with a username like ABC123 + 4-digit PIN (table app_users). Every scan is
--               recorded against the username. Staff can ONLY scan; they cannot read or change anything else.
-- All stock changes go through the functions below and every change is written to the log.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.user_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role    text not null check (role = 'admin')
);

create table if not exists public.app_users (
  username     text primary key check (username ~ '^[A-Z]{3}[0-9]{3}$'),
  full_name    text not null check (length(btrim(full_name)) > 0),
  pin_hash     text not null,
  active       boolean not null default true,
  failed       integer not null default 0,
  locked_until timestamptz,
  created_at   timestamptz not null default now()
);

create sequence if not exists public.barcode_seq;   -- barcodes are never reused, even after deleting an item

create table if not exists public.items (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (length(btrim(name)) > 0),
  barcode    text not null unique default ('INV-' || lpad(nextval('public.barcode_seq')::text, 5, '0')),
  qty        integer not null default 0 check (qty >= 0),
  baseline   integer not null default 0 check (baseline >= 0),   -- "total stock" used for the 1/4 alert
  created_at timestamptz not null default now()
);
create unique index if not exists items_name_ci on public.items (lower(name));

create table if not exists public.log (
  id        bigint generated always as identity primary key,
  t         timestamptz not null default now(),
  type      text not null,
  item_id   uuid,
  name      text,
  barcode   text,
  delta     integer,
  after     integer,
  by_user   text,      -- "ABC123 – Jane Smith" for staff, or the admin's email
  user_code text       -- staff username (null for admins)
);
create index if not exists log_user_code on public.log (user_code, id desc);

-- ---------- row level security ----------
alter table public.user_roles enable row level security;
alter table public.app_users  enable row level security;
alter table public.items      enable row level security;
alter table public.log        enable row level security;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from public.user_roles where user_id = auth.uid() and role = 'admin') $$;

drop policy if exists own_role   on public.user_roles;
drop policy if exists read_users on public.app_users;
drop policy if exists read_items on public.items;
drop policy if exists read_log   on public.log;
create policy own_role   on public.user_roles for select to authenticated using (user_id = auth.uid());
create policy read_users on public.app_users  for select to authenticated using (public.is_admin());
create policy read_items on public.items      for select to authenticated using (public.is_admin());
create policy read_log   on public.log        for select to authenticated using (public.is_admin());

revoke all on public.user_roles, public.app_users, public.items, public.log from anon, authenticated;
grant select on public.user_roles, public.items, public.log to authenticated;
grant select (username, full_name, active, failed, locked_until, created_at) on public.app_users to authenticated;  -- never pin_hash

-- ---------- internal helpers (not callable from the website) ----------
-- Checks a staff username + PIN. 5 wrong PINs lock that username for 15 minutes.
create or replace function public._login(p_username text, p_pin text, out status text, out u public.app_users)
language plpgsql security definer set search_path = public, extensions as $$
begin
  status := 'bad';
  select * into u from public.app_users where username = upper(btrim(p_username)) for update;
  if not found or not u.active then return; end if;
  if u.locked_until is not null and u.locked_until > now() then status := 'locked'; return; end if;
  if u.pin_hash = crypt(coalesce(p_pin, ''), u.pin_hash) then
    update public.app_users set failed = 0, locked_until = null where username = u.username;
    status := 'ok'; return;
  end if;
  update public.app_users
     set failed = case when failed + 1 >= 5 then 0 else failed + 1 end,
         locked_until = case when failed + 1 >= 5 then now() + interval '15 minutes' else locked_until end
   where username = u.username returning locked_until into u.locked_until;
  if u.locked_until is not null and u.locked_until > now() then status := 'locked'; end if;
end $$;

create or replace function public._take(p_barcode text, p_who text, p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.items;
begin
  update public.items set qty = qty - 1
   where lower(barcode) = lower(btrim(p_barcode)) and qty > 0
  returning * into r;
  if found then
    insert into public.log(type,item_id,name,barcode,delta,after,by_user,user_code)
    values ('take', r.id, r.name, r.barcode, -1, r.qty, p_who, p_code);
    return jsonb_build_object('status','ok','id',r.id,'name',r.name,'barcode',r.barcode,'qty',r.qty,'baseline',r.baseline);
  end if;
  select * into r from public.items where lower(barcode) = lower(btrim(p_barcode));
  if found then
    return jsonb_build_object('status','out','name',r.name,'barcode',r.barcode,'qty',0,'baseline',r.baseline);
  end if;
  return jsonb_build_object('status','unknown');
end $$;

-- ---------- staff functions (callable with the public key; the username + PIN are checked every time) ----------
create or replace function public.check_login(p_username text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l record;
begin
  select * into l from public._login(p_username, p_pin);
  if l.status <> 'ok' then return jsonb_build_object('status', l.status); end if;
  return jsonb_build_object('status','ok','username',(l.u).username,'name',(l.u).full_name);
end $$;

create or replace function public.take_one(p_username text, p_pin text, p_barcode text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l record;
begin
  select * into l from public._login(p_username, p_pin);
  if l.status <> 'ok' then return jsonb_build_object('status', l.status); end if;
  return public._take(p_barcode, (l.u).username || ' – ' || (l.u).full_name, (l.u).username);
end $$;

create or replace function public.my_recent(p_username text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l record;
begin
  select * into l from public._login(p_username, p_pin);
  if l.status <> 'ok' then return jsonb_build_object('status', l.status); end if;
  return jsonb_build_object('status','ok','rows', coalesce((
    select jsonb_agg(to_jsonb(x)) from (
      select t, name, barcode, after from public.log
       where type = 'take' and user_code = (l.u).username order by id desc limit 8) x), '[]'::jsonb));
end $$;

-- ---------- admin functions (admin must be signed in) ----------
create or replace function public.admin_take_one(p_barcode text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  return public._take(p_barcode, coalesce(auth.jwt()->>'email',''), null);
end $$;

create or replace function public.add_stock(p_name text, p_qty integer) returns public.items
language plpgsql security definer set search_path = public as $$
declare r public.items; n text := regexp_replace(btrim(p_name), '\s+', ' ', 'g'); kind text := 'restock';
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if n = '' or p_qty is null or p_qty < 0 then raise exception 'invalid name or quantity'; end if;
  update public.items set qty = qty + p_qty, baseline = qty + p_qty
   where lower(name) = lower(n) returning * into r;
  if not found then
    begin
      insert into public.items(name, qty, baseline) values (n, p_qty, p_qty) returning * into r;
      kind := 'new item';
    exception when unique_violation then
      update public.items set qty = qty + p_qty, baseline = qty + p_qty
       where lower(name) = lower(n) returning * into r;
    end;
  end if;
  insert into public.log(type,item_id,name,barcode,delta,after,by_user)
  values (kind, r.id, r.name, r.barcode, p_qty, r.qty, coalesce(auth.jwt()->>'email',''));
  return r;
end $$;

create or replace function public.rename_item(p_id uuid, p_name text) returns void
language plpgsql security definer set search_path = public as $$
declare n text := regexp_replace(btrim(p_name), '\s+', ' ', 'g');
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if n = '' then raise exception 'invalid name'; end if;
  update public.items set name = n where id = p_id;
end $$;

create or replace function public.correct_qty(p_id uuid, p_qty integer) returns void
language plpgsql security definer set search_path = public as $$
declare r public.items; old integer;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if p_qty is null or p_qty < 0 then raise exception 'invalid quantity'; end if;
  select qty into old from public.items where id = p_id for update;
  if not found then raise exception 'item not found'; end if;
  update public.items set qty = p_qty, baseline = greatest(baseline, p_qty) where id = p_id returning * into r;
  insert into public.log(type,item_id,name,barcode,delta,after,by_user)
  values ('correction', r.id, r.name, r.barcode, p_qty - old, r.qty, coalesce(auth.jwt()->>'email',''));
end $$;

create or replace function public.delete_item(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r public.items;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  delete from public.items where id = p_id returning * into r;
  if found then
    insert into public.log(type,item_id,name,barcode,delta,after,by_user)
    values ('deleted', r.id, r.name, r.barcode, -r.qty, 0, coalesce(auth.jwt()->>'email',''));
  end if;
end $$;

create or replace function public.create_app_user(p_username text, p_name text, p_pin text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare u text := upper(btrim(p_username));
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if u !~ '^[A-Z]{3}[0-9]{3}$' then raise exception 'username must be 3 letters then 3 numbers, e.g. ABC123'; end if;
  if p_pin !~ '^[0-9]{4}$' then raise exception 'PIN must be exactly 4 digits'; end if;
  insert into public.app_users(username, full_name, pin_hash)
  values (u, regexp_replace(btrim(p_name), '\s+', ' ', 'g'), crypt(p_pin, gen_salt('bf')));
exception when unique_violation then
  raise exception 'username % already exists', u;
end $$;

create or replace function public.set_user_pin(p_username text, p_pin text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if p_pin !~ '^[0-9]{4}$' then raise exception 'PIN must be exactly 4 digits'; end if;
  update public.app_users set pin_hash = crypt(p_pin, gen_salt('bf')), failed = 0, locked_until = null
   where username = upper(btrim(p_username));
end $$;

create or replace function public.set_user_name(p_username text, p_name text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if length(btrim(p_name)) = 0 then raise exception 'invalid name'; end if;
  update public.app_users set full_name = regexp_replace(btrim(p_name), '\s+', ' ', 'g')
   where username = upper(btrim(p_username));
end $$;

-- Deactivating keeps all of that person's history; they just cannot sign in any more.
create or replace function public.set_user_active(p_username text, p_active boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  update public.app_users set active = p_active, failed = 0, locked_until = null
   where username = upper(btrim(p_username));
end $$;

-- ---------- who may call what ----------
-- (Supabase grants new functions to everyone by default, so everything is revoked first.)
revoke all on function
  public.is_admin(), public._login(text,text), public._take(text,text,text),
  public.check_login(text,text), public.take_one(text,text,text), public.my_recent(text,text),
  public.admin_take_one(text), public.add_stock(text,integer), public.rename_item(uuid,text),
  public.correct_qty(uuid,integer), public.delete_item(uuid), public.create_app_user(text,text,text),
  public.set_user_pin(text,text), public.set_user_name(text,text), public.set_user_active(text,boolean)
  from public, anon, authenticated;

grant execute on function
  public.check_login(text,text), public.take_one(text,text,text), public.my_recent(text,text)
  to anon, authenticated;

grant execute on function
  public.is_admin(), public.admin_take_one(text), public.add_stock(text,integer), public.rename_item(uuid,text),
  public.correct_qty(uuid,integer), public.delete_item(uuid), public.create_app_user(text,text,text),
  public.set_user_pin(text,text), public.set_user_name(text,text), public.set_user_active(text,boolean)
  to authenticated;
