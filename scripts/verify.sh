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
#   APP_NAME     application name
#   ENVIRONMENT  one of: dev, staging, prod
#
# Optional env:
#   GITHUB_STEP_SUMMARY    appended with a markdown summary when set
#   VERIFY_SUMMARY_FILE    machine-readable summary path (default /tmp/verify-summary.txt)
#
# The app is served on its default *.azurewebsites.net hostname, covered by
# Azure's platform-managed wildcard certificate, so this script takes no domain
# or certificate input: there is no certificate for the template to manage. Dev
# is probed over its public endpoint; staging and prod are Private Endpoint only
# and are verified through the control plane alone.
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

require_env APP_NAME    "application name"
require_env ENVIRONMENT "one of: ${VALID_ENVIRONMENTS// /, }"

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

BASENAME="${APP_NAME}-${ENVIRONMENT}"
RG="rg-${BASENAME}"
ASP="asp-${BASENAME}"
APP="app-${BASENAME}"
PE="pe-${BASENAME}"
LAW="log-${BASENAME}"
APPI="appi-${BASENAME}"
AUTOSCALE="autoscale-${BASENAME}"
VNET="vnet-${BASENAME}"
# The flow-log storage account name is derived the same way the networking
# module derives it: "stflow" + the basename with dashes stripped, lowercased and
# truncated to the 24-character limit Azure imposes on storage account names.
FLOW_SA=$(echo "stflow${BASENAME//-/}" | tr '[:upper:]' '[:lower:]' | cut -c1-24)

# ── Per-environment expectations ──────────────────────────────────────────────
case "$ENVIRONMENT" in
  dev)
    EXPECTED_SKU=P0v3; EXPECTED_ZONE=false; EXPECTED_WORKERS=1; EXPECTED_SLOT=false
    EXPECTED_RETENTION=30; EXPECTED_AUTOSCALE=false; EXPECTED_AUTOSCALE_MIN=1
    PUBLIC_ENDPOINT=true ;;
  staging)
    EXPECTED_SKU=P1v3; EXPECTED_ZONE=false; EXPECTED_WORKERS=1; EXPECTED_SLOT=true
    EXPECTED_RETENTION=60; EXPECTED_AUTOSCALE=true;  EXPECTED_AUTOSCALE_MIN=1
    PUBLIC_ENDPOINT=false ;;
  prod)
    EXPECTED_SKU=P2v3; EXPECTED_ZONE=true;  EXPECTED_WORKERS=3; EXPECTED_SLOT=true
    EXPECTED_RETENTION=90; EXPECTED_AUTOSCALE=true;  EXPECTED_AUTOSCALE_MIN=3
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
echo "  Plan: $ASP  App: $APP  VNet: $VNET  Workspace: $LAW"

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
assert_eq "minTlsVersion"     "$(jq -r '.minTlsVersion    // "missing"' <<<"$CFG_JSON")" "1.3"
assert_eq "scmMinTlsVersion"  "$(jq -r '.scmMinTlsVersion // "missing"' <<<"$CFG_JSON")" "1.3"
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

# ── Log Analytics ─────────────────────────────────────────────────────────────
# Retention is asserted against the per-environment expectation (30/60/90) —
# a workspace that exists but silently fell back to the 30-day default would
# otherwise pass unnoticed in staging and prod.
echo "::group::Log Analytics"
LAW_JSON=$(az monitor log-analytics workspace show -n "$LAW" -g "$RG" -o json 2>/dev/null || echo '{}')
assert_eq "Workspace provisioningState" "$(jq -r '.provisioningState // "missing"' <<<"$LAW_JSON")" "Succeeded"
assert_eq "Workspace retentionInDays"   "$(jq -r '.retentionInDays   // 0'         <<<"$LAW_JSON")" "$EXPECTED_RETENTION"
echo "::endgroup::"

# ── Application Insights ──────────────────────────────────────────────────────
echo "::group::Application Insights"
APPI_JSON=$(az monitor app-insights component show -a "$APPI" -g "$RG" -o json 2>/dev/null || echo '{}')
assert_not_empty "App Insights instrumentation key" "$(jq -r '.instrumentationKey // "missing"' <<<"$APPI_JSON")"
assert_eq "App Insights workspace linked" "$(jq -r 'if .workspaceResourceId then "linked" else "unlinked" end' <<<"$APPI_JSON")" "linked"
echo "::endgroup::"

# ── Metric alerts ─────────────────────────────────────────────────────────────
# Existence and enablement only, not fired/resolved state: evaluating an alert
# needs metric history that a fresh apply does not have, so asserting on state
# would flake on every new deployment. `enabled` is configuration, not
# evaluation, so it is safe to assert. Metric alerts are hard-deleted on
# destroy, so a torn-down stack fails these checks correctly.
echo "::group::Metric alerts"
for ALERT in "alert-cpu-${BASENAME}" "alert-memory-${BASENAME}" "alert-health-${BASENAME}"; do
  ALERT_JSON=$(az monitor metrics alert show -n "$ALERT" -g "$RG" -o json 2>/dev/null || echo '{}')
  assert_eq "Alert $ALERT enabled" "$(jq -r '.enabled // "missing"' <<<"$ALERT_JSON")" "true"
done
echo "::endgroup::"

# ── Autoscale (staging + prod only) ───────────────────────────────────────────
echo "::group::Autoscale"
if [[ "$EXPECTED_AUTOSCALE" == true ]]; then
  AS_JSON=$(az monitor autoscale show -n "$AUTOSCALE" -g "$RG" -o json 2>/dev/null || echo '{}')
  assert_eq "Autoscale enabled"     "$(jq -r '.enabled // false'                        <<<"$AS_JSON")" "true"
  assert_ge "Autoscale min capacity" "$(jq -r '.profiles[0].capacity.minimum // 0'        <<<"$AS_JSON")" "$EXPECTED_AUTOSCALE_MIN"
  # 4 rules: CPU out/in + memory out/in — a missing scale-in rule must fail
  assert_ge "Autoscale rules"        "$(jq -r '(.profiles[0].rules // []) | length'       <<<"$AS_JSON")" 4
else
  pass "Autoscale disabled (not expected for $ENVIRONMENT)"
fi
echo "::endgroup::"

# ── Networking ────────────────────────────────────────────────────────────────
# The flow log itself lives in the Network Watcher resource group, which this
# script cannot address without knowing the region. Asserting the VNet and the
# flow-log storage account — both in the app resource group — verifies the same
# plumbing without needing a region input.
echo "::group::Networking"
VNET_JSON=$(az network vnet show -n "$VNET" -g "$RG" -o json 2>/dev/null || echo '{}')
assert_eq "VNet provisioningState" "$(jq -r '.provisioningState // "missing"' <<<"$VNET_JSON")" "Succeeded"
assert_ge "VNet subnets"           "$(jq -r '(.subnets // []) | length'       <<<"$VNET_JSON")" 2
FLOW_JSON=$(az storage account show -n "$FLOW_SA" -g "$RG" -o json 2>/dev/null || echo '{}')
assert_eq "Flow-log storage provisioningState" "$(jq -r '.provisioningState // "missing"' <<<"$FLOW_JSON")" "Succeeded"
echo "::endgroup::"

# ── Staging slot (staging + prod only) ────────────────────────────────────────
# The group is always emitted, even when no slot is expected, so a caller
# reading the output never has to infer whether a check was skipped or lost.
echo "::group::Staging slot"
if [[ "$EXPECTED_SLOT" == true ]]; then
  SLOT_STATE=$(az webapp deployment slot list -n "$APP" -g "$RG" \
    --query "[?name=='staging'].state | [0]" -o tsv 2>/dev/null || echo "missing")
  assert_eq "Staging slot state" "${SLOT_STATE:-missing}" "Running"

  # Swap-readiness: health check swaps with the general site config, so the
  # slot must mirror the app; the App Insights role name labels the slot, not
  # the container, so it must be pinned as a sticky (slot) setting.
  APP_HEALTH_PATH=$(jq -r '.healthCheckPath // "missing"' <<<"$CFG_JSON")
  SLOT_HEALTH_PATH=$(az webapp config show -n "$APP" -g "$RG" --slot staging \
    --query healthCheckPath -o tsv 2>/dev/null || echo "missing")
  assert_eq "Slot healthCheckPath mirrors app" "${SLOT_HEALTH_PATH:-missing}" "$APP_HEALTH_PATH"

  ROLE_NAME_STICKY=$(az webapp config appsettings list -n "$APP" -g "$RG" -o json 2>/dev/null \
    | jq -r '[.[] | select(.name=="APPLICATIONINSIGHTS_ROLE_NAME")][0].slotSetting // "missing"')
  assert_eq "APPLICATIONINSIGHTS_ROLE_NAME is sticky" "$ROLE_NAME_STICKY" "true"
else
  pass "Staging slot not provisioned (not expected for $ENVIRONMENT)"
fi
echo "::endgroup::"

# ── Public endpoint (dev only) ────────────────────────────────────────────────
# The app is served on its default *.azurewebsites.net hostname, which Azure
# covers with a platform-managed wildcard certificate — there is no certificate
# for this template to provision, bind, or renew, so nothing about certificate
# lifecycle is asserted here. What the request does prove is that the wildcard
# chain validates: curl verifies it by default, so a TLS failure surfaces as a
# connection error (000) rather than a status code.
#
# Dev keeps its public endpoint open for exactly this reason. Staging and prod
# are reachable only through the Private Endpoint, so a request from a runner
# outside the VNet would fail for a correct configuration — those environments
# rely on the control-plane assertions above instead.
echo "::group::Public endpoint"
HOSTNAME_DEFAULT=$(jq -r '.defaultHostName // ""' <<<"$WA_JSON")
if [[ "$PUBLIC_ENDPOINT" != "true" ]]; then
  pass "Public endpoint closed ($ENVIRONMENT is Private Endpoint only — no public probe)"
elif [[ -z "$HOSTNAME_DEFAULT" ]]; then
  fail "Default hostname: not resolvable from the Web App resource, cannot probe public endpoint"
else
  # curl already prints "000" to stdout when the connection fails, so the
  # fallback must replace that value rather than be appended to it — piping
  # through `|| echo 000` would yield the confusing "000000".
  HTTP_CODE=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" \
    "https://${HOSTNAME_DEFAULT}/" 2>/dev/null) || HTTP_CODE="000"
  assert_eq "HTTPS https://${HOSTNAME_DEFAULT}/" "${HTTP_CODE:-000}" "200"
fi
echo "::endgroup::"

# ── Summary ───────────────────────────────────────────────────────────────────
emit_summary

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo
  echo "FAILED: ${#FAILURES[@]} of $((${#PASSES[@]} + ${#FAILURES[@]})) checks"
  exit 1
fi

echo
echo "OK: all ${#PASSES[@]} checks passed."
