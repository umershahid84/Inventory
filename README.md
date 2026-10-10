# Stock Inventory

Barcode inventory system: add items (barcodes are created automatically), scan a barcode to take 1 item
out of stock, items turn red at ¼ of their total, and admins can print a list of what needs ordering.

Data is stored in an online database (Supabase), so it is safe if a browser is cleared and every
computer sees the same stock. Admins sign in with email + password; staff sign in with a username (ABC123) and a
4-digit PIN so every scan is tracked to a person.

* `index.html` – the app (hosted on Vercel as a static site)
* `config.js` – your Supabase URL and public key
* `supabase/schema.sql` – database tables, access rules and functions
* **`SETUP.md` – one-time setup steps**
