#!/usr/bin/env bash
# lint-role-columns.sh — förhindrar återfall av chip-namn-som-DB-nyckel-buggen.
#
# TVÅ CHECKS:
# 1. FRONTEND (html/ts/js): interpolation-check. Chip-slug-variabler får INTE
#    interpoleras in i DB-kolumnprefix (5 instanser 2026-07-13). Enforcerade
#    namn-konventioner:
#      - Chip-slug bär namnet: role, r, rRaw, rChip, window.role, localStorage.role
#      - Science-namn bär namnet: dbRole, dbRoleName, ecol, col
#      - Kolumnbygge får ENDAST använda science-namn-varianter
# 2. MIGRATIONS (SQL): literal-check. Nya migrationer får INTE referera
#    droppade chip-kolumnnamn (relevance_sci_sommelier m.fl. — 81 kolumner
#    droppade 2026-07-13 i 20260713140100). Skannar bara ADDED/MODIFIED
#    SQL-filer vs origin/main + staged — historiska drop/create-migrationer
#    (20260704120000, 20260707120000, 20260713140000, 20260713140100) är
#    frozen i main och flaggas därför inte.
#
# Kör lokalt: bash scripts/lint-role-columns.sh
# Wired-in: .githooks/pre-commit + .github/workflows/lint.yml
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v git >/dev/null; then
  echo "lint-role-columns: git required to scan tracked files" >&2
  exit 2
fi

EXIT_CODE=0

# =============================================================================
# CHECK 1 — Frontend interpolation (html/ts/js, tracked, exkl. migrations/scripts)
# =============================================================================

# Skanna endast tracked filer så backup/*.html och lokala scratch-filer
# i .gitignore inte flaggas.
FE_FILES=$(git ls-files '*.html' '*.ts' '*.js' \
  | grep -vE '^(node_modules/|supabase/migrations/|scripts/)' || true)

if [ -n "$FE_FILES" ]; then
  # Mönster: PREFIX_ följt av ${chipVar} eller "+chipVar
  PREFIX='(episteme|techne|phronesis|relevance_sci|has_episteme)'
  CHIP_VARS='role|r|rRaw|rChip|chipRole|window\.role|localStorage[^}]*'
  PATTERN="${PREFIX}_(\\\$\\{\\s*(${CHIP_VARS})\\s*\\}|['\"] *\\+ *(${CHIP_VARS})\\b)"

  MATCHES=$(echo "$FE_FILES" | xargs grep -HnE "$PATTERN" 2>/dev/null || true)
  # Undantag: DB_ROLES_ALL.map(r=>...) — iteratorn kommer från en array av
  # science-namn, så det är säkert. Endast rader som TYDLIGT innehåller
  # den konstruktionen på samma rad exemperas.
  MATCHES=$(echo "$MATCHES" | grep -vE 'DB_ROLES_ALL\.(map|forEach|filter)' || true)
  # Kommentarrader (// eller * ledande) exemperas.
  MATCHES=$(echo "$MATCHES" | grep -vE ':[[:space:]]*(//|\*)' || true)

  if [ -n "$MATCHES" ]; then
    echo ""
    echo "❌ chip-name variable used as DB-column suffix (5x recurrence 2026-07-13):"
    echo ""
    echo "$MATCHES"
    echo ""
    echo "Rule: never build column names from role/r/rRaw/rChip/window.role/localStorage.*"
    echo "Route via toDbRole() into dbRole/dbRoleName/ecol/col."
    echo "See commit 828ce57 (frontend) and bd11cd7 (weekly-newsletter)."
    EXIT_CODE=1
  fi
fi

# =============================================================================
# CHECK 2 — SQL migrations: literal referens till droppade chip-kolumner
# =============================================================================

# Bara added/modified migrations vs origin/main + staged (diff-scope, inte
# hela trädet). Historiska migrationer i main är frozen — flaggas inte.
MIG_STAGED=$(git diff --cached --name-only --diff-filter=AM -- 'supabase/migrations/*.sql' 2>/dev/null || true)
if git rev-parse --verify origin/main >/dev/null 2>&1; then
  MIG_AHEAD=$(git diff --name-only --diff-filter=AM origin/main...HEAD -- 'supabase/migrations/*.sql' 2>/dev/null || true)
else
  MIG_AHEAD=""
fi
MIG_FILES=$(printf '%s\n%s\n' "$MIG_STAGED" "$MIG_AHEAD" | grep -v '^$' | sort -u || true)

if [ -n "$MIG_FILES" ]; then
  # 81 droppade chip-namn (källa: 20260713140100_articles_drop_legacy_chip_cols.sql).
  DROPPED='\b(bridge_(episteme_techne|techne_phronesis)_(chef|fb_manager|food_researcher|gastronomy|sommelier)|(episteme|techne|phronesis)_(chef|creator|educator|fb_manager|fbmanager|food_researcher|gastronomy|hotelier|pastry_chef|researcher|restaurantmanager|sommelier|waiter|winebar)|relevance_(chef|creator|educator|fbmanager|hotelier|pastry_chef|researcher|restaurantmanager|sommelier|waiter|winebar)|relevance_sci_(chef|creator|educator|fb_manager|fbmanager|food_researcher|gastronomy|hotelier|researcher|restaurantmanager|sommelier|waiter|winebar)|relevance_val_(chef|creator|educator|sommelier|waiter))\b'

  MIG_MATCHES=$(echo "$MIG_FILES" | xargs grep -HnE "$DROPPED" 2>/dev/null || true)
  # SQL-kommentarrader (-- ledande) exemperas — historisk kontext OK att
  # nämna i doc-block så länge inte i CREATE FUNCTION-body.
  MIG_MATCHES=$(echo "$MIG_MATCHES" | grep -vE ':[[:space:]]*--' || true)

  if [ -n "$MIG_MATCHES" ]; then
    echo ""
    echo "❌ dropped chip-column referenced in new/modified migration (drop 2026-07-13):"
    echo ""
    echo "$MIG_MATCHES"
    echo ""
    echo "Rule: RPCer/vyer i nya migrationer måste använda science-namn:"
    echo "  sommelier       → sensory_pro"
    echo "  chef            → culinary_pro"
    echo "  gastronomy      → gastronomy_culture"
    echo "  fb_manager      → hospitality_mgmt"
    echo "  food_researcher → educator_researcher"
    echo "Se supabase/migrations/20260716120000_adopt_orphan_rpcs.sql för mönster."
    EXIT_CODE=1
  fi
fi

# =============================================================================
# Result
# =============================================================================

if [ $EXIT_CODE -eq 0 ]; then
  echo "OK — no chip-name-as-DB-key interpolation; no dropped chip-name in new migrations."
fi
exit $EXIT_CODE
