#!/bin/bash
# Genera env.js a partir de las env vars de Vercel (SUPABASE_URL, SUPABASE_ANON_KEY)
# en build time, para que trimartex-crm.html pueda leerlas como window.__ENV
# sin necesidad de un bundler. Ver SETUP.md.
set -euo pipefail

cat > env.js <<EOF
window.__ENV = {
  SUPABASE_URL: "${SUPABASE_URL:-}",
  SUPABASE_ANON_KEY: "${SUPABASE_ANON_KEY:-}"
};
EOF
