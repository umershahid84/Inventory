// Fill these two values in (Supabase > Project Settings > API). See SETUP.md.
// The anon key is meant to be public – the database rules in supabase/schema.sql protect your data.
window.INVENTORY_CONFIG = {
  SUPABASE_URL: "https://pfftlevijgfzpyegrufz.supabase.co",
  SUPABASE_ANON_KEY: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBmZnRsZXZpamdmenB5ZWdydWZ6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE2Njg0MzYsImV4cCI6MjEwNzI0NDQzNn0.C1qmmNIAwttm5T85rT1DcCawpyjGJdgZMLzKZN3tjM4",
  IDLE_SECONDS: 60   // staff are signed out automatically after this many seconds without scanning
};
