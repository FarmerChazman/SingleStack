#!/usr/bin/env bash
# Converge Cloudflare Email Routing across many domains from one config file.
#
#   scripts/cf-email-routing.sh plan   [config]   show what would change (default, read-only)
#   scripts/cf-email-routing.sh apply  [config]   make the changes
#   scripts/cf-email-routing.sh status [config]   show settings, DNS and rules per zone
#
# config defaults to deploy/cloudflare/email-routing.conf (see the .example).
#
# Environment:
#   CLOUDFLARE_API_TOKEN   required. Permissions (docs/03-cloudflare-email-routing.md §8):
#                            Zone: Zone Read, DNS Read, Zone Settings Edit, Email Routing Rules Edit
#                            Account: Email Routing Addresses Edit (only for "forward" rules)
#   CLOUDFLARE_ACCOUNT_ID  required when any rule uses "forward"
#   SUBADDRESSING=on|off   default on: user+tag@ matches the user@ rule (needed for
#                          Chatwoot's reply+<uuid>@ conversation-continuity addresses)
#   CF_API                 API base URL (override for testing)
#
# Safety: never deletes rules, never touches non-Email-Routing DNS records,
# refuses to enable a zone whose MX records point somewhere else.
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
require_cmd curl jq

mode="${1:-plan}"
config="${2:-$ROOT_DIR/deploy/cloudflare/email-routing.conf}"
case "$mode" in plan|apply|status) ;; *) die "usage: $0 plan|apply|status [config]" ;; esac
[[ -f "$config" ]] || die "config not found: $config (copy deploy/cloudflare/email-routing.conf.example)"
: "${CLOUDFLARE_API_TOKEN:?export CLOUDFLARE_API_TOKEN (see docs/03-cloudflare-email-routing.md §8)}"
CF_API="${CF_API:-https://api.cloudflare.com/client/v4}"
SUBADDRESSING="${SUBADDRESSING:-on}"

changes=0 problems=0
plan_line() { printf '  %s %s\n' "$1" "$2"; }
note_change() { changes=$((changes + 1)); plan_line "$1" "$2"; }
problem() { problems=$((problems + 1)); fail "$*"; }

# ── API helper ─────────────────────────────────────────────────────────────
# cf METHOD PATH [JSON]  -> prints .result-bearing body; non-zero + errors on failure
cf() {
  local method="$1" path="$2" body="${3:-}" out
  local args=(-sS --max-time 30 -X "$method" -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN")
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" --data "$body")
  if ! out="$(curl "${args[@]}" "$CF_API$path")"; then
    fail "network error: $method $path"; return 1
  fi
  if [[ "$(jq -r '.success // false' <<<"$out" 2>/dev/null)" != "true" ]]; then
    fail "$method $path -> $(jq -c '.errors // .' <<<"$out" 2>/dev/null || echo "$out")"
    return 1
  fi
  printf '%s' "$out"
}

# cf_all PATH  -> JSON array of .result across all pages
cf_all() {
  local path="$1" page=1 sep acc='[]' out pages
  [[ "$path" == *\?* ]] && sep='&' || sep='?'
  while :; do
    out="$(cf GET "${path}${sep}per_page=50&page=$page")" || return 1
    acc="$(jq -c --argjson acc "$acc" '$acc + (.result // [])' <<<"$out")"
    pages="$(jq -r '.result_info.total_pages // 1' <<<"$out")"
    (( page >= pages )) && break
    page=$((page + 1))
  done
  printf '%s' "$acc"
}

lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }

# ── parse config ───────────────────────────────────────────────────────────
declare -a ZONES=()
declare -A RULES=()      # zone -> newline-separated "address action target"
lineno=0
while IFS= read -r raw || [[ -n "$raw" ]]; do
  lineno=$((lineno + 1))
  line="${raw%%#*}"
  read -r zone address action target extra <<<"$line" || true
  [[ -z "${zone:-}" ]] && continue
  zone="$(lower "$zone")"; address="$(lower "${address:-}")"; action="$(lower "${action:-}")"
  [[ -z "${extra:-}" ]] || die "$config:$lineno: too many fields"
  [[ "$zone" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] || die "$config:$lineno: bad zone '$zone'"
  case "$action" in
    worker|forward) [[ -n "${target:-}" ]] || die "$config:$lineno: '$action' needs a target" ;;
    drop) [[ -z "${target:-}" ]] || die "$config:$lineno: 'drop' takes no target" ;;
    *) die "$config:$lineno: action must be worker|forward|drop" ;;
  esac
  if [[ "$address" != "*" ]]; then
    [[ "$address" =~ ^[^@[:space:]]+@([a-z0-9.-]+)$ ]] || die "$config:$lineno: bad address '$address'"
    dom="${BASH_REMATCH[1]}"
    [[ "$dom" == "$zone" || "$dom" == *".$zone" ]] || die "$config:$lineno: $address is not in zone $zone"
  fi
  [[ "$action" == forward && -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]] && die "CLOUDFLARE_ACCOUNT_ID is required for forward rules ($config:$lineno)"
  [[ -v "RULES[$zone]" ]] || ZONES+=("$zone")
  RULES[$zone]+="$address $action${target:+ $target}"$'\n'
done < "$config"
(( ${#ZONES[@]} > 0 )) || die "no rules in $config"

log "$mode: ${#ZONES[@]} zone(s) from ${config#"$ROOT_DIR"/}"

# ── destination addresses (account-level, shared by all zones) ─────────────
declare -A DEST_STATE=()   # email -> verified|pending
if [[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]] && grep -Eq '^[^#]*[[:space:]]forward[[:space:]]' "$config"; then
  dests="$(cf_all "/accounts/$CLOUDFLARE_ACCOUNT_ID/email/routing/addresses")" || die "cannot list destination addresses"
  while IFS=$'\t' read -r email verified; do
    [[ -n "$email" ]] || continue
    [[ "$verified" == null || -z "$verified" ]] && DEST_STATE[$(lower "$email")]=pending || DEST_STATE[$(lower "$email")]=verified
  done < <(jq -r '.[] | [.email, (.verified // "null")] | @tsv' <<<"$dests")

  log "destination addresses (account)"
  declare -A seen=()
  while read -r _ _ action target; do
    [[ "$action" == forward ]] || continue
    t="$(lower "$target")"; [[ -v "seen[$t]" ]] && continue; seen[$t]=1
    case "${DEST_STATE[$t]:-missing}" in
      verified) plan_line "=" "$t verified" ;;
      pending)  warn "$t awaiting verification — click the link Cloudflare emailed; its rules stay inactive until then" ;;
      missing)
        note_change "+" "add destination $t (Cloudflare emails a verification link)"
        if [[ "$mode" == apply ]]; then
          cf POST "/accounts/$CLOUDFLARE_ACCOUNT_ID/email/routing/addresses" "$(jq -nc --arg e "$t" '{email:$e}')" >/dev/null \
            && ok "verification email sent to $t" || problem "could not add $t"
          DEST_STATE[$t]=pending
        fi ;;
    esac
  done < <(for z in "${ZONES[@]}"; do printf '%s' "${RULES[$z]}" | sed "s/^/$z /"; done)
fi

# ── per zone ───────────────────────────────────────────────────────────────
for zone in "${ZONES[@]}"; do
  echo
  log "zone $zone"
  zone_id="$(cf GET "/zones?name=$zone" | jq -r '.result[0].id // empty')" || { problem "$zone: lookup failed"; continue; }
  [[ -n "$zone_id" ]] || { problem "$zone: not in this Cloudflare account (or the token can't see it)"; continue; }

  settings="$(cf GET "/zones/$zone_id/email/routing")" || { problem "$zone: cannot read Email Routing settings"; continue; }
  enabled="$(jq -r '.result.enabled // false' <<<"$settings")"
  status="$(jq -r '.result.status // "unknown"' <<<"$settings")"
  subaddr="$(jq -r '.result.support_subaddress // false' <<<"$settings")"

  # 1. MX records: Email Routing cannot coexist with another provider's MX.
  mx="$(cf_all "/zones/$zone_id/dns_records?type=MX&name=$zone")" || { problem "$zone: cannot read DNS"; continue; }
  foreign_mx="$(jq -r '.[] | select(.content | test("\\.mx\\.cloudflare\\.net\\.?$") | not) | "\(.priority) \(.content)"' <<<"$mx")"

  if [[ "$enabled" == true ]]; then
    plan_line "=" "Email Routing enabled (status: $status)"
    [[ "$status" == ready ]] || warn "status is '$status' — check Email Routing → Settings → DNS records"
  elif [[ -n "$foreign_mx" ]]; then
    problem "$zone has non-Cloudflare MX records; Email Routing would replace that mail service:"
    while IFS= read -r l; do printf '        MX %s\n' "$l" >&2; done <<<"$foreign_mx"
    warn "migrate deliberately (docs/03-cloudflare-email-routing.md §4.3), then re-run. Skipping this zone."
    continue
  else
    note_change "+" "enable Email Routing (adds + locks MX, SPF, DKIM records)"
    if [[ "$mode" == apply ]]; then
      cf POST "/zones/$zone_id/email/routing/dns" "$(jq -nc --arg n "$zone" '{name:$n}')" >/dev/null \
        && ok "enabled" || { problem "$zone: enable failed"; continue; }
    fi
  fi

  # 2. SPF: exactly one v=spf1 record, and it must include Cloudflare.
  txt="$(cf_all "/zones/$zone_id/dns_records?type=TXT&name=$zone")" || true
  spf_count="$(jq '[.[] | select(.content | test("v=spf1"))] | length' <<<"${txt:-[]}")"
  spf="$(jq -r '[.[] | select(.content | test("v=spf1"))][0].content // ""' <<<"${txt:-[]}" | tr -d '"')"
  if (( spf_count > 1 )); then
    problem "$zone has $spf_count SPF records — receivers treat that as a permanent error. Merge into one."
  elif (( spf_count == 1 )) && [[ "$spf" != *"include:_spf.mx.cloudflare.net"* ]]; then
    warn "SPF lacks Cloudflare. Edit it to: ${spf/v=spf1/v=spf1 include:_spf.mx.cloudflare.net}"
  elif (( spf_count == 1 )); then
    plan_line "=" "SPF ok: $spf"
  elif [[ "$enabled" == true ]]; then
    warn "no SPF record at $zone (Email Routing normally adds one)"
  fi

  # 3. Subaddressing.
  want_sub=false; [[ "$SUBADDRESSING" == on ]] && want_sub=true
  if [[ "$subaddr" == "$want_sub" ]]; then
    plan_line "=" "subaddressing $SUBADDRESSING"
  else
    note_change "~" "set subaddressing $SUBADDRESSING"
    [[ "$mode" == apply ]] && { cf PATCH "/zones/$zone_id/email/routing" "{\"support_subaddress\":$want_sub}" >/dev/null && ok "subaddressing $SUBADDRESSING" || problem "$zone: subaddressing update failed"; }
  fi

  # 4. Rules.
  existing="$(cf_all "/zones/$zone_id/email/routing/rules")" || { problem "$zone: cannot list rules"; continue; }
  declare -A managed=()
  while read -r address action target; do
    [[ -n "$address" ]] || continue
    if [[ "$action" == drop ]]; then
      want_actions='[{"type":"drop"}]'
    else
      want_actions="$(jq -nc --arg t "$action" --arg v "$target" '[{type:$t, value:[$v]}]')"
    fi
    [[ "$action" == forward && "${DEST_STATE[$(lower "$target")]:-}" != verified ]] \
      && warn "$address -> $target: destination not verified yet; the rule will stay inactive"

    if [[ "$address" == "*" ]]; then
      cur="$(cf GET "/zones/$zone_id/email/routing/rules/catch_all" | jq -c '.result')" || cur='{}'
      cur_actions="$(jq -c '[.actions[]? | {type} + (if .value then {value} else {} end)]' <<<"$cur")"
      cur_enabled="$(jq -r '.enabled // false' <<<"$cur")"
      if [[ "$cur_actions" == "$want_actions" && "$cur_enabled" == true ]]; then
        plan_line "=" "catch-all -> $action${target:+ $target}"
      else
        note_change "~" "catch-all -> $action${target:+ $target} (was: $(jq -r 'if .enabled then ([.actions[]? | .type + " " + ((.value // []) | join(","))] | join("; ")) else "disabled" end' <<<"$cur"))"
        if [[ "$mode" == apply ]]; then
          body="$(jq -nc --argjson a "$want_actions" '{name:"catch-all (managed by singlestack)", enabled:true, matchers:[{type:"all"}], actions:$a}')"
          cf PUT "/zones/$zone_id/email/routing/rules/catch_all" "$body" >/dev/null && ok "catch-all set" || problem "$zone: catch-all update failed"
        fi
      fi
      continue
    fi

    managed[$address]=1
    match="$(jq -c --arg a "$address" '[.[] | select(any(.matchers[]?; .type == "literal" and ((.value // "") | ascii_downcase) == $a))][0] // empty' <<<"$existing")"
    body="$(jq -nc --arg a "$address" --argjson acts "$want_actions" \
      '{name:("\($a) (managed by singlestack)"), enabled:true, matchers:[{type:"literal", field:"to", value:$a}], actions:$acts}')"
    if [[ -z "$match" ]]; then
      note_change "+" "$address -> $action${target:+ $target}"
      [[ "$mode" == apply ]] && { cf POST "/zones/$zone_id/email/routing/rules" "$body" >/dev/null && ok "created $address" || problem "create $address failed"; }
    else
      cur_actions="$(jq -c '[.actions[]? | {type} + (if .value then {value} else {} end)]' <<<"$match")"
      if [[ "$cur_actions" == "$want_actions" && "$(jq -r '.enabled' <<<"$match")" == true ]]; then
        plan_line "=" "$address -> $action${target:+ $target}"
      else
        note_change "~" "$address -> $action${target:+ $target} (was: $(jq -r '[.actions[]? | .type + " " + ((.value // []) | join(","))] | join("; ")' <<<"$match"), enabled=$(jq -r '.enabled' <<<"$match"))"
        rid="$(jq -r '.id // .tag' <<<"$match")"
        [[ "$mode" == apply ]] && { cf PUT "/zones/$zone_id/email/routing/rules/$rid" "$body" >/dev/null && ok "updated $address" || problem "update $address failed"; }
      fi
    fi
  done <<<"${RULES[$zone]}"

  # Unmanaged literal rules: report, never delete.
  while IFS=$'\t' read -r addr acts en; do
    [[ -n "$addr" && ! -v "managed[$addr]" ]] && plan_line "?" "unmanaged: $addr -> $acts (enabled=$en) — left as is"
  done < <(jq -r '.[] | select(any(.matchers[]?; .type == "literal")) |
      [((.matchers[] | select(.type == "literal") | .value) | ascii_downcase),
       ([.actions[]? | .type + " " + ((.value // []) | join(","))] | join("; ")), (.enabled|tostring)] | @tsv' <<<"$existing")
  unset managed

  # Subdomain addresses need the subdomain enabled in the dashboard (no API exists).
  while read -r address _; do
    [[ "$address" == *@* ]] || continue
    d="${address#*@}"; [[ "$d" == "$zone" ]] && continue
    sub_mx="$(cf_all "/zones/$zone_id/dns_records?type=MX&name=$d" | jq 'length')" || sub_mx=0
    (( sub_mx > 0 )) || warn "$address uses subdomain $d: enable it under Email Routing → Settings → Subdomains (dashboard only)"
  done <<<"${RULES[$zone]}"

  if [[ "$mode" == status ]]; then
    plan_line "i" "DNS records Email Routing expects:"
    cf GET "/zones/$zone_id/email/routing/dns" | jq -r '(.result.record // .result // [])[]? | "      \(.type) \(.name) \(.content) \(.priority // "")"' 2>/dev/null || true
  fi
done

echo
if [[ "$mode" == plan ]]; then
  (( changes > 0 )) && log "$changes change(s) planned — run: $0 apply ${2:-}" || ok "no changes"
elif [[ "$mode" == apply ]]; then
  log "applied $changes change(s)"
fi
(( problems == 0 )) || die "$problems problem(s) need attention (see ✗ above)"
