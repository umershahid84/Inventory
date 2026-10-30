-- Uniform Supplies – run this ONCE in Supabase > SQL Editor (after schema.sql). Safe to run again.
--
-- Tracks uniform stock per line of business, the employees who receive uniforms, what each employee
-- currently holds (so it can be collected when they leave), and a log of every change.
-- Everything is admin-only (staff scan-only logins cannot see or change any of it).

create table if not exists public.uniform_lines (
  code text primary key,
  name text not null,
  sort integer not null
);
create table if not exists public.uniform_roles (
  line_code text not null references public.uniform_lines(code),
  name      text not null,
  primary key (line_code, name)
);
insert into public.uniform_lines(code, name, sort) values
  ('public_parking','Public Parking',1),
  ('employee_parking','Employee Parking',2),
  ('ground_transportation','Ground Transportation',3),
  ('supervisors','Supervisors',4)
on conflict (code) do nothing;
insert into public.uniform_roles(line_code, name) values
  ('public_parking','Cashier'),
  ('employee_parking','Bus Driver'),
  ('employee_parking','Admin Staff'),
  ('ground_transportation','Landside Transportation Specialist'),
  ('supervisors','Supervisor')
on conflict do nothing;

create table if not exists public.uniform_variants (
  id      integer generated always as identity primary key,
  garment text not null,
  fit     text not null check (fit in ('Men','Women','Unisex')),
  size    text not null,
  sort    integer not null,
  unique (garment, fit, size)
);

create table if not exists public.uniform_stock (
  line_code  text    not null references public.uniform_lines(code),
  variant_id integer not null references public.uniform_variants(id),
  qty        integer not null default 0 check (qty >= 0),
  baseline   integer not null default 0 check (baseline >= 0),   -- stock level when last received (1/4 alert)
  primary key (line_code, variant_id)
);

create table if not exists public.uniform_employees (
  id            uuid primary key default gen_random_uuid(),
  emp_no        text,
  full_name     text not null check (length(btrim(full_name)) > 0),
  line_code     text not null references public.uniform_lines(code),
  role          text not null,
  status        text not null default 'active' check (status in ('active','terminated')),
  terminated_on date,
  created_at    timestamptz not null default now(),
  foreign key (line_code, role) references public.uniform_roles(line_code, name)
);
create unique index if not exists uniform_emp_no on public.uniform_employees (lower(emp_no)) where emp_no is not null;

create table if not exists public.uniform_issues (
  id            bigint generated always as identity primary key,
  employee_id   uuid not null references public.uniform_employees(id),
  variant_id    integer not null references public.uniform_variants(id),
  line_code     text not null references public.uniform_lines(code),   -- stock pool it came from / returns to
  qty           integer not null check (qty > 0),
  returned_qty  integer not null default 0 check (returned_qty >= 0),   -- came back into stock
  discarded_qty integer not null default 0 check (discarded_qty >= 0),  -- lost / damaged / thrown away
  outstanding   integer generated always as (qty - returned_qty - discarded_qty) stored,
  from_stock    boolean not null default true,
  issued_at     timestamptz not null default now(),
  issued_by     text,
  note          text,
  closed_at     timestamptz,
  check (returned_qty + discarded_qty <= qty)
);
create index if not exists uniform_issues_emp on public.uniform_issues (employee_id);
create index if not exists uniform_issues_open on public.uniform_issues (outstanding) where outstanding > 0;

create table if not exists public.uniform_log (
  id            bigint generated always as identity primary key,
  t             timestamptz not null default now(),
  type          text not null,        -- stock, correction, issue, return, discard, void, new size, new employee, status
  line_code     text,
  garment       text,
  fit           text,
  size          text,
  qty           integer,
  employee_id   uuid,
  employee_name text,
  note          text,
  by_user       text
);

-- ---------- sizes (editable later with "Add size" in the app) ----------
do $$
declare
  waist text[] := array['28','30','32','34','36','38','40','42','44'];
  wwaist text[] := array['0','2','4','6','8','10','12','14','16','18','20'];
  mtop text[] := array['S','M','L','XL','2XL','3XL','4XL','5XL'];
  wtop text[] := array['XS','S','M','L','XL','2XL','3XL','4XL'];
  uni text[] := array['S/M','L/XL'];
  vest text[] := array['S/M','L/XL','2XL/3XL','4XL/5XL'];
  n integer := 0; g text; s text;
begin
  if exists (select 1 from public.uniform_variants) then return; end if;   -- only seed once
  foreach g in array array['Pants','Shorts'] loop
    foreach s in array waist  loop n := n+1; insert into public.uniform_variants(garment,fit,size,sort) values (g,'Men',s,n); end loop;
    foreach s in array wwaist loop n := n+1; insert into public.uniform_variants(garment,fit,size,sort) values (g,'Women',s,n); end loop;
  end loop;
  foreach g in array array['Shirt – Half sleeve','Shirt – Full sleeve','Jacket','Raincoat'] loop
    foreach s in array mtop loop n := n+1; insert into public.uniform_variants(garment,fit,size,sort) values (g,'Men',s,n); end loop;
    foreach s in array wtop loop n := n+1; insert into public.uniform_variants(garment,fit,size,sort) values (g,'Women',s,n); end loop;
  end loop;
  foreach s in array vest loop n := n+1; insert into public.uniform_variants(garment,fit,size,sort) values ('High-vis vest','Unisex',s,n); end loop;
  foreach g in array array['Beanie','Hat'] loop
    foreach s in array uni loop n := n+1; insert into public.uniform_variants(garment,fit,size,sort) values (g,'Unisex',s,n); end loop;
  end loop;
end $$;

-- ---------- row level security: admins read, nobody writes directly ----------
alter table public.uniform_lines     enable row level security;
alter table public.uniform_roles     enable row level security;
alter table public.uniform_variants  enable row level security;
alter table public.uniform_stock     enable row level security;
alter table public.uniform_employees enable row level security;
alter table public.uniform_issues    enable row level security;
alter table public.uniform_log       enable row level security;

do $$
declare t text;
begin
  foreach t in array array['uniform_lines','uniform_roles','uniform_variants','uniform_stock','uniform_employees','uniform_issues','uniform_log'] loop
    execute format('drop policy if exists admin_read on public.%I', t);
    execute format('create policy admin_read on public.%I for select to authenticated using (public.is_admin())', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;

-- ---------- functions ----------
create or replace function public._uwho() returns text language sql stable as $$ select coalesce(auth.jwt()->>'email','') $$;

create or replace function public.uniform_add_stock(p_line text, p_variant integer, p_qty integer) returns void
language plpgsql security definer set search_path = public as $$
declare v public.uniform_variants; s public.uniform_stock;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'quantity must be 1 or more'; end if;
  select * into v from public.uniform_variants where id = p_variant;
  if not found then raise exception 'unknown size'; end if;
  insert into public.uniform_stock(line_code, variant_id, qty, baseline) values (p_line, p_variant, p_qty, p_qty)
  on conflict (line_code, variant_id)
  do update set qty = public.uniform_stock.qty + excluded.qty, baseline = public.uniform_stock.qty + excluded.qty
  returning * into s;
  insert into public.uniform_log(type,line_code,garment,fit,size,qty,note,by_user)
  values ('stock', p_line, v.garment, v.fit, v.size, p_qty, 'now '||s.qty, public._uwho());
end $$;

create or replace function public.uniform_correct_stock(p_line text, p_variant integer, p_qty integer) returns void
language plpgsql security definer set search_path = public as $$
declare v public.uniform_variants; old integer;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if p_qty is null or p_qty < 0 then raise exception 'invalid quantity'; end if;
  select * into v from public.uniform_variants where id = p_variant;
  select qty into old from public.uniform_stock where line_code = p_line and variant_id = p_variant for update;
  if not found then raise exception 'no stock record to correct'; end if;
  update public.uniform_stock set qty = p_qty, baseline = greatest(baseline, p_qty)
   where line_code = p_line and variant_id = p_variant;
  insert into public.uniform_log(type,line_code,garment,fit,size,qty,note,by_user)
  values ('correction', p_line, v.garment, v.fit, v.size, p_qty - old, 'now '||p_qty, public._uwho());
end $$;

create or replace function public.uniform_add_variant(p_garment text, p_fit text, p_size text) returns integer
language plpgsql security definer set search_path = public as $$
declare id integer; g text := btrim(p_garment); s text := btrim(p_size);
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if g = '' or s = '' then raise exception 'garment and size are required'; end if;
  insert into public.uniform_variants(garment, fit, size, sort)
  values (g, p_fit, s, coalesce((select max(sort) from public.uniform_variants), 0) + 1)
  returning uniform_variants.id into id;
  insert into public.uniform_log(type,garment,fit,size,by_user) values ('new size', g, p_fit, s, public._uwho());
  return id;
exception when unique_violation then
  raise exception 'that size already exists';
end $$;

create or replace function public.uniform_add_employee(p_emp_no text, p_name text, p_line text, p_role text) returns uuid
language plpgsql security definer set search_path = public as $$
declare id uuid; n text := regexp_replace(btrim(p_name), '\s+', ' ', 'g'); e text := nullif(btrim(p_emp_no), '');
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if n = '' then raise exception 'name is required'; end if;
  if not exists (select 1 from public.uniform_roles where line_code = p_line and name = p_role) then
    raise exception 'that job is not part of that line of business';
  end if;
  insert into public.uniform_employees(emp_no, full_name, line_code, role) values (e, n, p_line, p_role) returning uniform_employees.id into id;
  insert into public.uniform_log(type,employee_id,employee_name,by_user) values ('new employee', id, n, public._uwho());
  return id;
exception when unique_violation then
  raise exception 'employee number % is already used', e;
end $$;

create or replace function public.uniform_update_employee(p_id uuid, p_emp_no text, p_name text, p_line text, p_role text) returns void
language plpgsql security definer set search_path = public as $$
declare n text := regexp_replace(btrim(p_name), '\s+', ' ', 'g'); e text := nullif(btrim(p_emp_no), '');
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if n = '' then raise exception 'name is required'; end if;
  if not exists (select 1 from public.uniform_roles where line_code = p_line and name = p_role) then
    raise exception 'that job is not part of that line of business';
  end if;
  update public.uniform_employees set emp_no = e, full_name = n, line_code = p_line, role = p_role where id = p_id;
exception when unique_violation then
  raise exception 'employee number % is already used', e;
end $$;

create or replace function public.uniform_set_status(p_id uuid, p_terminated boolean) returns void
language plpgsql security definer set search_path = public as $$
declare n text;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  update public.uniform_employees
     set status = case when p_terminated then 'terminated' else 'active' end,
         terminated_on = case when p_terminated then current_date else null end
   where id = p_id returning full_name into n;
  insert into public.uniform_log(type,employee_id,employee_name,note,by_user)
  values ('status', p_id, n, case when p_terminated then 'terminated' else 'reactivated' end, public._uwho());
end $$;

-- Gives uniforms to an employee. Normally takes them out of that line's stock; tick "record only"
-- (p_from_stock = false) for items the employee already has from before this system.
create or replace function public.uniform_issue(p_employee uuid, p_variant integer, p_qty integer, p_note text, p_from_stock boolean)
returns bigint language plpgsql security definer set search_path = public as $$
declare emp public.uniform_employees; v public.uniform_variants; iid bigint; left_qty integer;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'quantity must be 1 or more'; end if;
  select * into emp from public.uniform_employees where id = p_employee;
  if not found then raise exception 'employee not found'; end if;
  if emp.status <> 'active' then raise exception 'this employee is terminated – reactivate first'; end if;
  select * into v from public.uniform_variants where id = p_variant;
  if not found then raise exception 'unknown size'; end if;
  if p_from_stock then
    update public.uniform_stock set qty = qty - p_qty
     where line_code = emp.line_code and variant_id = p_variant and qty >= p_qty
     returning qty into left_qty;
    if not found then
      raise exception 'not enough % % % in % stock', v.garment, v.fit, v.size,
        (select name from public.uniform_lines where code = emp.line_code);
    end if;
  end if;
  insert into public.uniform_issues(employee_id, variant_id, line_code, qty, from_stock, issued_by, note)
  values (emp.id, p_variant, emp.line_code, p_qty, p_from_stock, public._uwho(), nullif(btrim(p_note), ''))
  returning id into iid;
  insert into public.uniform_log(type,line_code,garment,fit,size,qty,employee_id,employee_name,note,by_user)
  values ('issue', emp.line_code, v.garment, v.fit, v.size, p_qty, emp.id, emp.full_name,
          case when p_from_stock then null else 'record only (stock not deducted)' end, public._uwho());
  return iid;
end $$;

-- Takes items back from an employee: p_back go back into stock, p_discard are lost / damaged / thrown away.
create or replace function public.uniform_return(p_issue bigint, p_back integer, p_discard integer, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare i public.uniform_issues; v public.uniform_variants; emp public.uniform_employees;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if coalesce(p_back,0) < 0 or coalesce(p_discard,0) < 0 or coalesce(p_back,0) + coalesce(p_discard,0) = 0 then
    raise exception 'enter how many were returned or discarded';
  end if;
  select * into i from public.uniform_issues where id = p_issue for update;
  if not found then raise exception 'record not found'; end if;
  if p_back + p_discard > i.outstanding then raise exception 'only % still outstanding', i.outstanding; end if;
  select * into v from public.uniform_variants where id = i.variant_id;
  select * into emp from public.uniform_employees where id = i.employee_id;
  update public.uniform_issues
     set returned_qty = returned_qty + p_back, discarded_qty = discarded_qty + p_discard,
         closed_at = case when outstanding - p_back - p_discard = 0 then now() else null end
   where id = p_issue;
  if p_back > 0 then
    insert into public.uniform_stock(line_code, variant_id, qty, baseline) values (i.line_code, i.variant_id, p_back, p_back)
    on conflict (line_code, variant_id) do update
      set qty = public.uniform_stock.qty + p_back,
          baseline = greatest(public.uniform_stock.baseline, public.uniform_stock.qty + p_back);
    insert into public.uniform_log(type,line_code,garment,fit,size,qty,employee_id,employee_name,note,by_user)
    values ('return', i.line_code, v.garment, v.fit, v.size, p_back, emp.id, emp.full_name, nullif(btrim(p_note),''), public._uwho());
  end if;
  if p_discard > 0 then
    insert into public.uniform_log(type,line_code,garment,fit,size,qty,employee_id,employee_name,note,by_user)
    values ('discard', i.line_code, v.garment, v.fit, v.size, p_discard, emp.id, emp.full_name, nullif(btrim(p_note),''), public._uwho());
  end if;
end $$;

-- Undo a mistaken issue (only if nothing has been returned from it yet).
create or replace function public.uniform_void_issue(p_issue bigint) returns void
language plpgsql security definer set search_path = public as $$
declare i public.uniform_issues; v public.uniform_variants; emp public.uniform_employees;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  select * into i from public.uniform_issues where id = p_issue for update;
  if not found then raise exception 'record not found'; end if;
  if i.returned_qty > 0 or i.discarded_qty > 0 then raise exception 'items were already returned from this record'; end if;
  select * into v from public.uniform_variants where id = i.variant_id;
  select * into emp from public.uniform_employees where id = i.employee_id;
  if i.from_stock then
    insert into public.uniform_stock(line_code, variant_id, qty, baseline) values (i.line_code, i.variant_id, i.qty, i.qty)
    on conflict (line_code, variant_id) do update
      set qty = public.uniform_stock.qty + i.qty, baseline = greatest(public.uniform_stock.baseline, public.uniform_stock.qty + i.qty);
  end if;
  delete from public.uniform_issues where id = p_issue;
  insert into public.uniform_log(type,line_code,garment,fit,size,qty,employee_id,employee_name,note,by_user)
  values ('void', i.line_code, v.garment, v.fit, v.size, i.qty, emp.id, emp.full_name, 'issue cancelled', public._uwho());
end $$;

revoke all on function
  public._uwho(), public.uniform_add_stock(text,integer,integer), public.uniform_correct_stock(text,integer,integer),
  public.uniform_add_variant(text,text,text), public.uniform_add_employee(text,text,text,text),
  public.uniform_update_employee(uuid,text,text,text,text), public.uniform_set_status(uuid,boolean),
  public.uniform_issue(uuid,integer,integer,text,boolean), public.uniform_return(bigint,integer,integer,text),
  public.uniform_void_issue(bigint)
  from public, anon, authenticated;
grant execute on function
  public.uniform_add_stock(text,integer,integer), public.uniform_correct_stock(text,integer,integer),
  public.uniform_add_variant(text,text,text), public.uniform_add_employee(text,text,text,text),
  public.uniform_update_employee(uuid,text,text,text,text), public.uniform_set_status(uuid,boolean),
  public.uniform_issue(uuid,integer,integer,text,boolean), public.uniform_return(bigint,integer,integer,text),
  public.uniform_void_issue(bigint)
  to authenticated;
