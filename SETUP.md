# One-time setup (about 10 minutes)

## 1. Create the database
1. Go to <https://supabase.com>, sign up, and click **New project** (any name, choose a strong database
   password and the region closest to you). Wait until it finishes starting.
2. Open **SQL Editor → New query**, paste the entire contents of `supabase/schema.sql`, and click **Run**.
   You should see "Success".

## 2. Turn off public sign-up
**Authentication → Sign In / Providers → Email** → switch **off** "Allow new users to sign up" and save.
(Otherwise anyone who finds the site could create an account.)

## 3. Create the staff logins
**Authentication → Users → Add user → Create new user.** Enter an email and password, and tick
**Auto Confirm User**. Create one for yourself and one for each person who will scan.

Then, in **SQL Editor**, give each person a role (replace the emails):

```sql
insert into public.user_roles (user_id, role)
select id, 'admin' from auth.users where email = 'you@example.com';

insert into public.user_roles (user_id, role)
select id, 'scanner' from auth.users where email = 'warehouse@example.com';
```

* **admin** – add items, restock, rename, correct counts, delete, print labels and the order list, export.
* **scanner** – scan items out and view stock/history only.

## 4. Connect the app
**Project Settings → API**: copy the **Project URL** and the **anon / public** key into `config.js`,
commit, and push. Vercel redeploys automatically. (The anon key is designed to be public; the rules in
`schema.sql` stop anyone who is not signed in from seeing or changing anything. **Never** put the
`service_role` key in this file.)

## 5. Keeping your data safe
* Everything is stored in Supabase, not in the browser, so clearing a browser loses nothing.
* Every change is recorded in the History tab with who made it.
* Use **Export items / Export history (CSV)** on the Inventory tab now and then to keep your own copy.
* Supabase's **free** plan pauses a project after about a week with no use and has no downloadable daily
  backups. For a business you can't afford to lose data from, use the **Pro plan** (daily automatic backups).
