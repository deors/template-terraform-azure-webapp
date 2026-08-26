#!/usr/bin/env bash
# verify.sh
# Canonical post-apply verification for this infrastructure template.
#
# Asserts that the deployed Web App stack matches the per-environment
# expectations encoded by this template's terraform/environments/<env>.
# The platform-eng orchestrator checks out the provisioned infrastructure repo
# and invokes this script at its canonical path (scripts/verify.sh) after
# `tofu apply`. Keeping the verification logic here — next to the
# Terraform that defines those expectations — means every infra template owns
# and governs its own assertions, so the orchestrator stays template-agnostic.
#
# Required env:
#   APP_NAME     application name, used as the resource name prefix
#   ENVIRONMENT  one of: dev, staging, prod
#
# Optional env:
#   CUSTOM_DOMAIN          custom hostname bound to the Web App. When set, adds
#                          hostname binding, certificate and end-to-end HTTPS
#                          checks. The HTTPS reachability check additionally
#                          requires a public endpoint, so it runs for dev only —
#                          staging and prod use Private Endpoint by design.
#   GITHUB_STEP_SUMMARY    appended with a markdown summary when set
#   VERIFY_SUMMARY_FILE    machine-readable summary path (default /tmp/verify-summary.txt)
#
# Exit codes:
#   0  every check passed
#   1  checks ran, at least one failed
#   2  invalid invocation — a required variable is missing or ENVIRONMENT is not
#      one of dev/staging/prod. No checks ran.
#
# All three exits write the summary file and, when GITHUB_STEP_SUMMARY is set,
# the markdown summary — including exit 2. A caller can therefore always parse
# the summary file and never has to distinguish "failed" from "never started".

set -uo pipefail   # no -e: collect all failures, then exit at the end

VALID_ENVIRONMENTS="dev staging prod"

PASSES=()
FAILURES=()

pass()  { PASSES+=("$1"); echo "  ✓ $1"; }
fail()  { FAILURES+=("$1"); echo "  ✗ $1"; }

assert_eq() {
  # $1 = label, $2 = actual, $3 = expected
  if [[ "$2" == "$3" ]]; then pass "$1 = $2"
  else fail "$1: expected '$3', got '$2'"; fi
}

assert_ge() {
  # $1 = label, $2 = actual, $3 = expected minimum
  if [[ "$2" -ge "$3" ]] 2>/dev/null; then pass "$1 = $2 (≥ $3)"
  else fail "$1: expected ≥ $3, got '$2'"; fi
}

assert_not_empty() {
  # $1 = label, $2 = actual value
  # Guards against the script's own // "missing" jq fallbacks as well as
  # the literal strings az returns for absent optional fields.
  if [[ -n "$2" && "$2" != "null" && "$2" != "None" && "$2" != "missing" ]]; then
    pass "$1 = $2"
  else
    fail "$1: expected non-empty value, got '$2'"
  fi
}

# ── Summary emission ──────────────────────────────────────────────────────────
# Every exit path routes through here, so a caller can parse the same two
# artefacts (the step summary and the summary file) regardless of whether the
# run passed, failed its checks, or was invoked incorrectly. Array expansions
# are guarded by a length test because bash 3.2 — still the default on macOS —
# treats "${empty[@]}" as an unbound variable under `set -u`.
emit_summary() {
  local app="${APP_NAME:-(unset)}"
  local env="${ENVIRONMENT:-(unset)}"

  {
    echo "## Verify · \`$app\` / \`$env\`"
    echo ""
    echo "**Passed:** ${#PASSES[@]} · **Failed:** ${#FAILURES[@]}"
    echo ""
    if [[ ${#FAILURES[@]} -gt 0 ]]; then
      echo "### Failures"
      printf -- '- %s\n' "${FAILURES[@]}"
      echo ""
    fi
    echo "<details><summary>All checks</summary>"
    echo ""
    [[ ${#PASSES[@]}   -gt 0 ]] && printf -- '- ✓ %s\n' "${PASSES[@]}"
    [[ ${#FAILURES[@]} -gt 0 ]] && printf -- '- ✗ %s\n' "${FAILURES[@]}"
    echo ""
    echo "</details>"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

  {
    echo "environment=${env}"
    echo "passed=${#PASSES[@]}"
    echo "failed=${#FAILURES[@]}"
  } > "${VERIFY_SUMMARY_FILE:-/tmp/verify-summary.txt}"
}

# ── Input validation ──────────────────────────────────────────────────────────
# Both inputs are validated here, before the first Azure CLI call. Every problem
# is collected and reported together rather than aborting on the first one, and
# the failure path is the same one check failures take — summary always written,
# so the caller never has to special-case "the script died before producing output".
require_env() {
  # $1 = variable name, $2 = what it is, for the error message
  if [[ -z "${!1:-}" ]]; then
    FAILURES+=("$1 is required — $2")
    echo "  ✗ $1 is required — $2" >&2
  fi
}

require_env APP_NAME    "application name, used as the resource name prefix"
require_env ENVIRONMENT "one of: ${VALID_ENVIRONMENTS// /, }"

# CUSTOM_DOMAIN is optional: absent means hostname binding, certificate, and
# HTTPS reachability groups are skipped, which is correct for deployments
# without a custom domain.
CUSTOM_DOMAIN="${CUSTOM_DOMAIN:-}"

if [[ -n "${ENVIRONMENT:-}" && " ${VALID_ENVIRONMENTS} " != *" ${ENVIRONMENT} "* ]]; then
  FAILURES+=("ENVIRONMENT must be one of: ${VALID_ENVIRONMENTS// /, } — got '${ENVIRONMENT}'")
  echo "  ✗ ENVIRONMENT must be one of: ${VALID_ENVIRONMENTS// /, } — got '${ENVIRONMENT}'" >&2
fi

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  emit_summary
  echo >&2
  echo "INVALID INVOCATION: ${#FAILURES[@]} problem(s); no checks were run." >&2
  exit 2
fi

PREFIX="${APP_NAME}-${ENVIRONMENT}"
RG="rg-${PREFIX}"
ASP="asp-${PREFIX}"
APP="app-${PREFIX}"
PE="pe-${PREFIX}"

# ── Per-environment expectations ──────────────────────────────────────────────
case "$ENVIRONMENT" in
  dev)
    EXPECTED_SKU=P0v3; EXPECTED_ZONE=false; EXPECTED_WORKERS=1; EXPECTED_SLOT=false
    PUBLIC_ENDPOINT=true ;;
  staging)
    EXPECTED_SKU=P1v3; EXPECTED_ZONE=false; EXPECTED_WORKERS=1; EXPECTED_SLOT=true
    PUBLIC_ENDPOINT=false ;;
  prod)
    EXPECTED_SKU=P2v3; EXPECTED_ZONE=true;  EXPECTED_WORKERS=3; EXPECTED_SLOT=true
    PUBLIC_ENDPOINT=false ;;
  *)
    # Unreachable — ENVIRONMENT is validated above. Kept so that adding a value
    # to VALID_ENVIRONMENTS without adding its expectations here fails loudly,
    # and through the same reporting path as every other exit.
    FAILURES+=("ENVIRONMENT '$ENVIRONMENT' is accepted but has no expectation set")
    emit_summary
    echo "INVALID INVOCATION: no expectation set for '$ENVIRONMENT'." >&2
    exit 2 ;;
esac

echo "Verifying $APP_NAME / $ENVIRONMENT (RG=$RG)"

# ── Resource group ────────────────────────────────────────────────────────────
echo "::group::Resource group"
RG_STATE=$(az group show -n "$RG" --query properties.provisioningState -o tsv 2>/dev/null || echo "missing")
assert_eq "RG provisioningState" "$RG_STATE" "Succeeded"
echo "::endgroup::"

# ── App Service Plan ──────────────────────────────────────────────────────────
echo "::group::App Service Plan"
ASP_JSON=$(az appservice plan show -n "$ASP" -g "$RG" -o json 2>/dev/null || echo '{}')
assert_eq "ASP SKU"           "$(jq -r '.sku.name      // "missing"' <<<"$ASP_JSON")" "$EXPECTED_SKU"
# .properties.zoneRedundant is the authoritative location; the flat
# .zoneRedundant at the top of the response is unreliably populated by `az`
# (often null even when the plan is genuinely zone-redundant).
assert_eq "ASP zoneRedundant" "$(jq -r '.properties.zoneRedundant // .zoneRedundant // false' <<<"$ASP_JSON")" "$EXPECTED_ZONE"
# .sku.capacity is the authoritative worker count; .numberOfWorkers is unreliable
# across CLI versions and often reports 0 even when capacity is set.
assert_ge "ASP workerCount"   "$(jq -r '.sku.capacity // 0'          <<<"$ASP_JSON")" "$EXPECTED_WORKERS"
echo "::endgroup::"

# ── Web App ───────────────────────────────────────────────────────────────────
echo "::group::Web App"
WA_JSON=$(az webapp show -n "$APP" -g "$RG" -o json 2>/dev/null || echo '{}')
assert_eq "WebApp state"      "$(jq -r '.state         // "missing"' <<<"$WA_JSON")" "Running"
assert_eq "WebApp httpsOnly"  "$(jq -r '.httpsOnly     // false'     <<<"$WA_JSON")" "true"
assert_eq "WebApp identity"   "$(jq -r '.identity.type // "None"'    <<<"$WA_JSON")" "UserAssigned"

CFG_JSON=$(az webapp config show -n "$APP" -g "$RG" -o json 2>/dev/null || echo '{}')
assert_eq "minTlsVersion"     "$(jq -r '.minTlsVersion // "missing"' <<<"$CFG_JSON")" "1.3"
assert_eq "ftpsState"         "$(jq -r '.ftpsState     // "missing"' <<<"$CFG_JSON")" "Disabled"
assert_eq "http20Enabled"     "$(jq -r '.http20Enabled // false'     <<<"$CFG_JSON")" "true"
echo "::endgroup::"

# ── Private Endpoint ──────────────────────────────────────────────────────────
echo "::group::Private Endpoint"
PE_JSON=$(az network private-endpoint show -n "$PE" -g "$RG" -o json 2>/dev/null || echo '{}')
assert_eq "PE provisioningState" "$(jq -r '.provisioningState // "missing"' <<<"$PE_JSON")" "Succeeded"
echo "::endgroup::"

# ── Diagnostic settings ───────────────────────────────────────────────────────
echo "::group::Diagnostic settings"
WA_ID=$(jq -r '.id // ""' <<<"$WA_JSON")
if [[ -n "$WA_ID" ]]; then
  # `az monitor diagnostic-settings list` returns a flat array, not a wrapped
  # {value:[…]} object — use length(@) on the array root.
  DIAG_COUNT=$(az monitor diagnostic-settings list --resource "$WA_ID" --query 'length(@)' -o tsv 2>/dev/null || echo 0)
  assert_ge "WebApp diagnostic settings" "$DIAG_COUNT" 1
fi
echo "::endgroup::"

# ── Staging slot (staging + prod only) ────────────────────────────────────────
if [[ "$EXPECTED_SLOT" == true ]]; then
  echo "::group::Staging slot"
  SLOT_STATE=$(az webapp deployment slot list -n "$APP" -g "$RG" \
    --query "[?name=='staging'].state | [0]" -o tsv 2>/dev/null || echo "missing")
  assert_eq "Staging slot state" "${SLOT_STATE:-missing}" "Running"
  echo "::endgroup::"
fi

# ── Custom domain (optional) ──────────────────────────────────────────────────
# Skipped entirely when CUSTOM_DOMAIN is not set.
if [[ -n "$CUSTOM_DOMAIN" ]]; then
  echo "::group::Custom domain"

  # Hostname binding — must exist with SniEnabled SSL state
  BINDING_JSON=$(az webapp config hostname list --webapp-name "$APP" -g "$RG" \
    --query "[?name=='$CUSTOM_DOMAIN'] | [0]" -o json 2>/dev/null || echo '{}')
  BINDING_SSL=$(jq -r '.sslState // "missing"' <<<"$BINDING_JSON")
  assert_eq "Custom hostname SSL state" "$BINDING_SSL" "SniEnabled"

  # Managed certificate — must exist and must not be expired
  CERT_JSON=$(az webapp config ssl list -g "$RG" \
    --query "[?subjectName=='$CUSTOM_DOMAIN'] | [0]" -o json 2>/dev/null || echo '{}')
  CERT_THUMBPRINT=$(jq -r '.thumbprint // "missing"' <<<"$CERT_JSON")
  assert_not_empty "Managed certificate thumbprint" "$CERT_THUMBPRINT"

  EXPIRY_DATE=$(jq -r '.expirationDate // "missing"' <<<"$CERT_JSON" | cut -c1-10)
  TODAY=$(date -u +%Y-%m-%d)
  if [[ "$EXPIRY_DATE" > "$TODAY" ]]; then
    pass "Managed certificate not expired (expires $EXPIRY_DATE)"
  else
    fail "Managed certificate expired or expiry unknown (expiry=$EXPIRY_DATE)"
  fi

  # End-to-end HTTPS reachability — dev only. Staging and prod expose the Web
  # App through Private Endpoint only, so an HTTP request from a runner with no
  # VNet access will correctly fail and must not be asserted.
  if [[ "$PUBLIC_ENDPOINT" == "true" ]]; then
    HTTP_CODE=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" "https://$CUSTOM_DOMAIN/" 2>/dev/null || echo "000")
    assert_eq "HTTPS $CUSTOM_DOMAIN" "$HTTP_CODE" "200"
  else
    pass "HTTPS reachability skipped ($ENVIRONMENT uses Private Endpoint — no public access)"
  fi

  echo "::endgroup::"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
emit_summary

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo
  echo "FAILED: ${#FAILURES[@]} of $((${#PASSES[@]} + ${#FAILURES[@]})) checks"
  exit 1
fi

echo
echo "OK: all ${#PASSES[@]} checks passed."
