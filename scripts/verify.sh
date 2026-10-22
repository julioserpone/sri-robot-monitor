#!/usr/bin/env bash
#
# Verificación local completa, pensada para ejecutarse ANTES de subir cambios.
#
# Hace lo mismo que el CI, pero en tu Mac y sin gastar minutos de Actions:
#   1. Archivos obligatorios y plantillas de GitHub.
#   2. Ausencia de secretos versionados y de claves de AWS en el código.
#   3. Compilación (Debug) y suite completa de pruebas.
#   4. Resumen con el número de pruebas ejecutadas.
#
# Uso:
#   ./scripts/verify.sh              # todo
#   ./scripts/verify.sh --quick      # solo higiene (sin compilar)
#   SKIP_TESTS=1 ./scripts/verify.sh # compila, no corre pruebas
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

PROJECT="SriRobotMonitor.xcodeproj"
SCHEME="SriRobotMonitor"
DERIVED=".build/local"
QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
FAILED=0

ok()   { echo "  ${GREEN}✓${RESET} $1"; }
fail() { echo "  ${RED}✗${RESET} $1"; FAILED=1; }
note() { echo "  ${YELLOW}·${RESET} $1"; }
step() { echo; echo "${BOLD}$1${RESET}"; }

echo "${BOLD}Verificación de SriRobotMonitor${RESET}"

# ---------------------------------------------------------------- higiene ----
step "1/4 Archivos y convenciones"

required=(
  README.md CHANGELOG.md CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md LICENSE
  docs/ARCHITECTURE.md docs/TESTING.md docs/AI_USAGE.md
  .github/pull_request_template.md .github/dependabot.yml
  .github/workflows/ci.yml .github/rulesets/main.json
  .github/ISSUE_TEMPLATE/bug_report.yml
  .github/ISSUE_TEMPLATE/feature_request.yml
  .github/ISSUE_TEMPLATE/config.yml
  scripts/verify.sh
)
missing=()
for file in "${required[@]}"; do
  [[ -f "$file" ]] || missing+=("$file")
done
if [[ ${#missing[@]} -eq 0 ]]; then
  ok "Están los ${#required[@]} archivos obligatorios"
else
  fail "Faltan: ${missing[*]}"
fi

if git ls-files 2>/dev/null | grep -qE '(^|/)(\.env$|.*\.p12$|.*\.pem$|id_rsa$)'; then
  fail "Hay archivos sensibles versionados"
else
  ok "Sin archivos sensibles versionados"
fi

if grep -RInE 'AKIA[0-9A-Z]{16}' --include='*.swift' SriRobotMonitor Tests >/dev/null 2>&1; then
  fail "Posible Access Key ID de AWS en el código"
else
  ok "Sin claves de AWS escritas en el código"
fi

# Nombres de archivo en inglés (el contenido puede estar en español).
snake_es=$(find . -maxdepth 2 -iname "*.md" -not -path "./.build/*" -not -path "./build/*" \
  | grep -iE "(arquitectura|pruebas|uso_ia|guia|cambios)" || true)
if [[ -n "$snake_es" ]]; then
  fail "Documentos con nombre en español: $(echo "$snake_es" | tr '\n' ' ')"
else
  ok "Nombres de documentos en inglés"
fi

if command -v python3 >/dev/null && command -v git >/dev/null; then
  python3 - <<'PY' || true
import yaml
from pathlib import Path
bad = []
for path in Path(".github").rglob("*.yml"):
    try:
        list(yaml.safe_load_all(path.read_text()))
    except Exception as exc:
        bad.append(f"{path}: {exc}")
if bad:
    print("  \033[31m✗\033[0m YAML inválido: " + "; ".join(bad))
    raise SystemExit(1)
PY
  [[ $? -eq 0 ]] && ok "YAML de .github válido"
fi

if [[ $QUICK -eq 1 ]]; then
  echo
  [[ $FAILED -eq 0 ]] && echo "${GREEN}Higiene correcta.${RESET}" || echo "${RED}Hay fallos de higiene.${RESET}"
  exit $FAILED
fi

# ------------------------------------------------------------- compilación ----
step "2/4 Compilación"
build_log="$(mktemp -t sri-build)"
if xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
     -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
     CODE_SIGNING_ALLOWED=NO build >"$build_log" 2>&1; then
  warnings=$(grep -c "warning:" "$build_log" || true)
  ok "Compila sin errores (${warnings} advertencia(s))"
  [[ "$warnings" -gt 0 ]] && note "Revisa el log si las advertencias son nuevas"
else
  fail "La compilación falló"
  grep -E "error:" "$build_log" | head -30
  grep -E "error:" "$build_log" | head -30 | while read -r line; do
    echo "::error::$line"
  done
fi

# ------------------------------------------------------------------ tests ----
step "3/4 Pruebas"

if [[ "${SKIP_TESTS:-0}" == "1" ]]; then
  note "Omitidas (SKIP_TESTS=1)"
elif [[ $FAILED -ne 0 ]]; then
  note "Omitidas: primero corrige la compilación"
else
  test_log="$(mktemp -t sri-test)"
  if xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
       -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
       CODE_SIGNING_ALLOWED=NO test >"$test_log" 2>&1; then
    executed=$(grep -E "Executed [0-9]+ tests?" "$test_log" | tail -1 | sed -E 's/.*Executed ([0-9]+).*/\1/')
    ok "${executed:-?} pruebas en verde"
  else
    fail "Hay pruebas en rojo"
    grep -E "error:|XCTAssert.*failed|Test Case .* failed" "$test_log" | head -25
    echo
    note "Log completo: $test_log"
  fi
fi

# ---------------------------------------------------------------- resumen ----
step "4/4 Resumen"
if [[ $FAILED -eq 0 ]]; then
  echo "  ${GREEN}${BOLD}Todo listo para subir.${RESET}"
  echo "  Siguiente paso: git push y abrir el PR (sin fusionar)."
else
  echo "  ${RED}${BOLD}Hay fallos: no subas todavía.${RESET}"
fi
exit $FAILED
