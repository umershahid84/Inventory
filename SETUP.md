# One-time setup (about 10 minutes)

## 1. Create the database
1. Go to <https://supabase.com>, sign up, and click **New project** (any name, choose a strong database
   password and the region closest to you). Wait until it finishes starting.
2. Open **SQL Editor → New query**, paste the entire contents of `supabase/schema.sql`, and click **Run**.
   You should see "Success".

## 2. Create the administrators (as many as you like)
Administrators sign in with an email and password and can add items, restock, print labels and the
order list, manage staff users and see the full history.

1. **Authentication → Sign In / Providers → Email** → switch **off** "Allow new users to sign up" and save.
   (Otherwise anyone who finds the site could create an account.)
2. **Authentication → Users → Add user → Create new user.** Enter an email and password and tick
   **Auto Confirm User**. Repeat for each administrator.
3. In **SQL Editor**, make each of them an administrator (replace the email; run once per admin):

```sql
insert into public.user_roles (user_id, role)
select id, 'admin' from auth.users where email = 'you@example.com';
```

To add another administrator later, repeat steps 2 and 3. To remove one, delete the user under
Authentication → Users.

## 3. Connect the app
**Project Settings → API**: copy the **Project URL** and the **anon / public** key into `config.js`,
commit, and push. Vercel redeploys automatically. (The anon key is designed to be public; the rules in
`schema.sql` protect the data. **Never** put the `service_role` key in this file.)

## 4. Add staff users (done inside the app)
Sign in as an administrator → **Staff users** → enter
* **Username** – 3 letters + 3 numbers, e.g. `ABC123` (every person gets their own),
* **Full name**, and
* **PIN** – 4 digits (several people may share the same PIN).

Staff open the site, choose **Staff**, type their username and PIN, and scan. Every scan is recorded with
their username and name (see **History**). They are signed out automatically after 60 seconds without
scanning (change `IDLE_SECONDS` in `config.js`), so the next person must sign in as themselves.
Staff can only scan – they cannot see or change anything else.

Admins can reset a PIN, rename, or deactivate a user at any time (deactivating keeps their history).
After 5 wrong PINs a username is locked for 15 minutes; resetting the PIN unlocks it straight away.

## 5. Keeping your data safe
* Everything is stored in Supabase, not in the browser, so clearing a browser loses nothing.
* Every change is recorded in the History tab with who made it.
* Use **Export items / Export history (CSV)** on the Inventory tab now and then to keep your own copy.
* Supabase's **free** plan pauses a project after about a week with no use and has no downloadable daily
  backups. For a business you can't afford to lose data from, use the **Pro plan** (daily automatic backups).
