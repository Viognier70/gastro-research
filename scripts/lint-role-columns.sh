#!/usr/bin/env bash
# lint-role-columns.sh — förhindrar återfall av chip-namn-som-DB-nyckel-buggen
# (5 instanser 2026-07-13). Regeln: DB-kolumnprefix (episteme_/techne_/
# phronesis_/relevance_sci_/has_episteme_) får INTE följas av interpolation
# av en variabel med chip-signatur. Enforcerade namn-konventioner:
#   - Chip-slug bär namnet: role, r, rRaw, rChip, window.role, localStorage.role
#   - Science-namn bär namnet: dbRole, dbRoleName, ecol, col
#   - Kolumnbygge får ENDAST använda science-namn-varianter
#
# Kör lokalt: bash scripts/lint-role-columns.sh
# Wired-in: .githooks/pre-commit + .github/workflows/lint.yml
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Skanna endast tracked filer så backup/*.html och lokala scratch-filer
# i .gitignore inte flaggas.
if ! command -v git >/dev/null; then
  echo "lint-role-columns: git required to scan tracked files" >&2
  exit 2
fi

FILES=$(git ls-files '*.html' '*.ts' '*.js' \
  | grep -vE '^(node_modules/|supabase/migrations/|scripts/)' || true)

if [ -z "$FILES" ]; then
  echo "OK — no files to scan."
  exit 0
fi

# Mönster: PREFIX_ följt av ${chipVar} eller "+chipVar
PREFIX='(episteme|techne|phronesis|relevance_sci|has_episteme)'
CHIP_VARS='role|r|rRaw|rChip|chipRole|window\.role|localStorage[^}]*'
PATTERN="${PREFIX}_(\\\$\\{\\s*(${CHIP_VARS})\\s*\\}|['\"] *\\+ *(${CHIP_VARS})\\b)"

MATCHES=$(echo "$FILES" | xargs grep -HnE "$PATTERN" 2>/dev/null || true)
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
  exit 1
fi

echo "OK — no chip-name-as-DB-key interpolation found."
exit 0
