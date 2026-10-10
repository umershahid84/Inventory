-- Stock Inventory – database schema for Supabase.
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
-- Safe to read first: all stock changes go through the functions below, every change is
-- written to the log, and only signed-in users that have a row in user_roles can see anything.

create table if not exists public.user_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role    text not null check (role in ('admin','scanner'))
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
  id       bigint generated always as identity primary key,
  t        timestamptz not null default now(),
  type     text not null,
  item_id  uuid,
  name     text,
  barcode  text,
  delta    integer,
  after    integer,
  by_email text
);

-- ---------- row level security ----------
alter table public.user_roles enable row level security;
alter table public.items      enable row level security;
alter table public.log        enable row level security;

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as
$$ select role from public.user_roles where user_id = auth.uid() $$;

drop policy if exists own_role   on public.user_roles;
drop policy if exists read_items on public.items;
drop policy if exists read_log   on public.log;
create policy own_role   on public.user_roles for select to authenticated using (user_id = auth.uid());
create policy read_items on public.items      for select to authenticated using (public.my_role() is not null);
create policy read_log   on public.log        for select to authenticated using (public.my_role() is not null);

revoke all on public.user_roles, public.items, public.log from anon, authenticated;
grant select on public.user_roles, public.items, public.log to authenticated;

-- ---------- functions (the only way to change data) ----------
create or replace function public.take_one(p_barcode text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.items;
begin
  if public.my_role() is null then raise exception 'not authorised'; end if;
  update public.items set qty = qty - 1
   where lower(barcode) = lower(btrim(p_barcode)) and qty > 0
  returning * into r;
  if found then
    insert into public.log(type,item_id,name,barcode,delta,after,by_email)
    values ('take', r.id, r.name, r.barcode, -1, r.qty, coalesce(auth.jwt()->>'email',''));
    return jsonb_build_object('status','ok','id',r.id,'name',r.name,'barcode',r.barcode,'qty',r.qty,'baseline',r.baseline);
  end if;
  select * into r from public.items where lower(barcode) = lower(btrim(p_barcode));
  if found then
    return jsonb_build_object('status','out','name',r.name,'barcode',r.barcode,'qty',0,'baseline',r.baseline);
  end if;
  return jsonb_build_object('status','unknown');
end $$;

create or replace function public.add_stock(p_name text, p_qty integer) returns public.items
language plpgsql security definer set search_path = public as $$
declare r public.items; n text := regexp_replace(btrim(p_name), '\s+', ' ', 'g'); kind text := 'restock';
begin
  if public.my_role() is distinct from 'admin' then raise exception 'admin only'; end if;
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
  insert into public.log(type,item_id,name,barcode,delta,after,by_email)
  values (kind, r.id, r.name, r.barcode, p_qty, r.qty, coalesce(auth.jwt()->>'email',''));
  return r;
end $$;

create or replace function public.rename_item(p_id uuid, p_name text) returns void
language plpgsql security definer set search_path = public as $$
declare n text := regexp_replace(btrim(p_name), '\s+', ' ', 'g');
begin
  if public.my_role() is distinct from 'admin' then raise exception 'admin only'; end if;
  if n = '' then raise exception 'invalid name'; end if;
  update public.items set name = n where id = p_id;
end $$;

create or replace function public.correct_qty(p_id uuid, p_qty integer) returns void
language plpgsql security definer set search_path = public as $$
declare r public.items; old integer;
begin
  if public.my_role() is distinct from 'admin' then raise exception 'admin only'; end if;
  if p_qty is null or p_qty < 0 then raise exception 'invalid quantity'; end if;
  select qty into old from public.items where id = p_id for update;
  if not found then raise exception 'item not found'; end if;
  update public.items set qty = p_qty, baseline = greatest(baseline, p_qty) where id = p_id returning * into r;
  insert into public.log(type,item_id,name,barcode,delta,after,by_email)
  values ('correction', r.id, r.name, r.barcode, p_qty - old, r.qty, coalesce(auth.jwt()->>'email',''));
end $$;

create or replace function public.delete_item(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r public.items;
begin
  if public.my_role() is distinct from 'admin' then raise exception 'admin only'; end if;
  delete from public.items where id = p_id returning * into r;
  if found then
    insert into public.log(type,item_id,name,barcode,delta,after,by_email)
    values ('deleted', r.id, r.name, r.barcode, -r.qty, 0, coalesce(auth.jwt()->>'email',''));
  end if;
end $$;

revoke all on function public.my_role(), public.take_one(text), public.add_stock(text,integer),
  public.rename_item(uuid,text), public.correct_qty(uuid,integer), public.delete_item(uuid) from public, anon;
grant execute on function public.my_role(), public.take_one(text), public.add_stock(text,integer),
  public.rename_item(uuid,text), public.correct_qty(uuid,integer), public.delete_item(uuid) to authenticated;
