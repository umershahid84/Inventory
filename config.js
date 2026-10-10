// Fill these two values in (Supabase > Project Settings > API). See SETUP.md.
// The anon key is meant to be public – the database rules in supabase/schema.sql protect your data.
window.INVENTORY_CONFIG = {
  SUPABASE_URL: "https://YOUR-PROJECT.supabase.co",
  SUPABASE_ANON_KEY: "YOUR-ANON-PUBLIC-KEY",
  IDLE_SECONDS: 60   // staff are signed out automatically after this many seconds without scanning
};
