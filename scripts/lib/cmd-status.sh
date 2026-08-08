#!/usr/bin/env bash
# lib/cmd-status.sh — citt status <package_id> [--scan-id <id>|--scan-number <n>].
# GET /api/status/{pkg}. By default the API returns the last COMPLETED scan (so a
# running rescan stays invisible until it finishes); pass --scan-id/--scan-number
# to poll a SPECIFIC scan's live status (queued/analyzing included). Sends the
# stored token when present (so owners can see private/in-flight scans) and falls
# back to an anonymous GET otherwise; the token never leaks to stdout/argv/xtrace.
# Emits compact status JSON to stdout (id, package_id, status, current_scan_status,
# overall_score, letter_grade, completed_at, platform, severity counts, stage);
# not-found exits non-zero with {"error":"not_found",...}.

# Resolve the newest in-flight (queued/analyzing) scan id for a package, so a
# plain status call can hand the user a ready-to-run --scan-id poll command.
# Echoes the scan_id (or nothing). Best-effort; never fatal. $1 = url-encoded pkg.
_status_inflight_scan_id() {
  local enc="$1" path="/api/apps/${enc}/scans" code
  if _have_token && _load_token_to_staging; then
    _build_curl_cfg
    code="$(_curl_auth_get "$path")"
  else
    code="$(_curl_pub_get "$path")"
  fi
  [ "$code" = "200" ] || return 0
  local sf; sf="$(cat "${_CITT_RESP_FILE}" 2>/dev/null || true)"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$sf" | jq -r '[.scans[]? | select(.status=="analyzing" or .status=="queued")] | sort_by(.scan_number) | last | .scan_id // empty' 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$sf" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
c=[s for s in d.get("scans",[]) if s.get("status") in ("analyzing","queued")]
c.sort(key=lambda s: s.get("scan_number") or 0)
print(c[-1]["scan_id"] if c else "")' 2>/dev/null
  fi
}

citt_cmd_status() {
  local pkg="" scan_id="" scan_number=""

  # Parse positional package id + flags (no getopts — portability).
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --scan-id)
        shift; scan_id="${1:-}"
        [ -z "$scan_id" ] && { emit_err "citt status: --scan-id needs a value"; exit 2; }
        ;;
      --scan-number)
        shift; scan_number="${1:-}"
        case "$scan_number" in
          ''|*[!0-9]*) emit_err "citt status: --scan-number needs a positive integer"; exit 2 ;;
        esac
        ;;
      --help|-h)
        cat >&1 <<'USAGE'
Usage: citt status <package_id> [--scan-id <id> | --scan-number <n>]

  citt status <pkg>                  Latest scan. NOTE: while a rescan runs, this
                                     shows the last COMPLETED scan; the JSON's
                                     current_scan_status is "queued"/"analyzing"
                                     when a fresh scan is in flight.
  citt status <pkg> --scan-id <id>   Poll a SPECIFIC scan's live status (use the
                                     scan_id that `citt rescan` printed).
  citt status <pkg> --scan-number <n>  Poll scan #n for the package.

Sends your stored token when present (needed to view private/in-flight scans you
own); otherwise queries the public scorecard anonymously.
USAGE
        return 0
        ;;
      -*)
        emit_err "citt status: unknown flag: $1 (see: citt status --help)"
        exit 2
        ;;
      *)
        if [ -z "$pkg" ]; then pkg="$1"; else emit_err "citt status: unexpected extra argument: $1"; exit 2; fi
        ;;
    esac
    shift
  done

  if [ -z "$pkg" ]; then
    emit_err "usage: citt status <package_id> [--scan-id <id> | --scan-number <n>]"
    exit 2
  fi
  if [ -n "$scan_id" ] && [ -n "$scan_number" ]; then
    emit_err "citt status: use --scan-id OR --scan-number, not both"
    exit 2
  fi

  # URL-encode the package id (defensive; ids are [A-Za-z0-9._-]).
  local enc
  if command -v python3 >/dev/null 2>&1; then
    enc="$(python3 -c 'import sys,urllib.parse; sys.stdout.write(urllib.parse.quote(sys.argv[1], safe=""))' "$pkg" 2>/dev/null)" || enc="$pkg"
  else
    enc="$pkg"
  fi

  # Build the path + optional scan selector query.
  local path="/api/status/${enc}"
  if [ -n "$scan_id" ]; then
    local senc
    if command -v python3 >/dev/null 2>&1; then
      senc="$(python3 -c 'import sys,urllib.parse; sys.stdout.write(urllib.parse.quote(sys.argv[1], safe=""))' "$scan_id" 2>/dev/null)" || senc="$scan_id"
    else
      senc="$scan_id"
    fi
    path="${path}?scan_id=${senc}"
  elif [ -n "$scan_number" ]; then
    path="${path}?scan_number=${scan_number}"
  fi

  # Send the token when we have one (owners/admins can then see private and
  # in-flight scans); otherwise an anonymous public GET. Soft auth: a missing
  # token is NOT fatal here (public scorecards are readable without one).
  local code
  if _have_token && _load_token_to_staging; then
    _build_curl_cfg
    code="$(_curl_auth_get "$path")"
  else
    code="$(_curl_pub_get "$path")"
  fi

  case "$code" in
    200)
      : # handled below
      ;;
    401)
      # A stale token blocked a request that anonymous access might still serve
      # (public scan). Retry once, unauthenticated, before giving up.
      code="$(_curl_pub_get "$path")"
      if [ "$code" != "200" ]; then
        emit_err "citt status: not authorized (HTTP $code) — re-authenticate with: citt auth"
        exit 1
      fi
      ;;
    403)
      emit_err "citt status: access denied — this scan is private; run 'citt auth' as the owner"
      exit 1
      ;;
    404)
      local out
      if command -v jq >/dev/null 2>&1; then
        out="$(jq -c --arg pkg "$pkg" '{"error":"not_found","package_id":$pkg,"detail":(.detail // "Package or scan not found")}' "${_CITT_RESP_FILE}" 2>/dev/null \
          || printf '{"error":"not_found","package_id":"%s"}' "$pkg")"
      else
        out="$(printf '{"error":"not_found","package_id":"%s"}' "$pkg")"
      fi
      emit_json "$out"
      if [ -n "$scan_id" ]; then
        emit_err "citt status: scan '${scan_id}' not found for '${pkg}'"
      elif [ -n "$scan_number" ]; then
        emit_err "citt status: scan #${scan_number} not found for '${pkg}'"
      else
        emit_err "citt status: package '${pkg}' not found"
      fi
      exit 1
      ;;
    "")
      emit_err "citt status: could not reach the CITT API"
      exit 1
      ;;
    *)
      emit_err "citt status: unexpected HTTP ${code} from /api/status/${pkg}"
      exit 1
      ;;
  esac

  # Parse the StatusResponse JSON.
  local body
  body="$(cat "${_CITT_RESP_FILE}" 2>/dev/null || true)"

  if command -v jq >/dev/null 2>&1; then
    # letter_grade: A=90+, B=80-89, C=70-79, D=55-69, F=<55 (null when no score).
    local out
    out="$(printf '%s' "$body" | jq -c '
      def grade(s):
        if s == null then null
        elif s >= 90 then "A"
        elif s >= 80 then "B"
        elif s >= 70 then "C"
        elif s >= 55 then "D"
        else "F"
        end;
      {
        id:                   .id,
        package_id:           .package_id,
        status:               .status,
        current_scan_status:  .current_scan_status,
        overall_score:        .overall_score,
        letter_grade:         (grade(.overall_score)),
        completed_at:         .completed_at,
        platform:             (.platform // "android"),
        scan_type:            (.scan_type // "full"),
        progress_message:     .progress_message,
        total_findings_count: .total_findings_count,
        critical_findings_count: .critical_findings_count,
        high_findings_count:  .high_findings_count,
        medium_findings_count:.medium_findings_count,
        low_findings_count:   .low_findings_count,
        info_findings_count:  .info_findings_count,
        recommendation:       .recommendation,
        current_stage:        .current_stage,
        queue_position:       .queue_position
      }
    ' 2>/dev/null)"
    if [ -z "$out" ]; then
      emit_err "citt status: failed to parse response"
      exit 1
    fi
    emit_json "$out"
  else
    # Fallback: extract scalars with _json_get.
    local id status current_scan_status overall_score completed_at platform scan_type progress_message
    local total_findings critical_findings high_findings medium_findings low_findings info_findings
    local recommendation current_stage queue_position letter_grade

    id="$(_json_get id "$body")"
    status="$(_json_get status "$body")"
    current_scan_status="$(_json_get current_scan_status "$body")"
    overall_score="$(_json_get overall_score "$body")"
    completed_at="$(_json_get completed_at "$body")"
    platform="$(_json_get platform "$body")"; [ -z "$platform" ] && platform="android"
    scan_type="$(_json_get scan_type "$body")"; [ -z "$scan_type" ] && scan_type="full"
    progress_message="$(_json_get progress_message "$body")"
    total_findings="$(_json_get total_findings_count "$body")"
    critical_findings="$(_json_get critical_findings_count "$body")"
    high_findings="$(_json_get high_findings_count "$body")"
    medium_findings="$(_json_get medium_findings_count "$body")"
    low_findings="$(_json_get low_findings_count "$body")"
    info_findings="$(_json_get info_findings_count "$body")"
    recommendation="$(_json_get recommendation "$body")"
    current_stage="$(_json_get current_stage "$body")"
    queue_position="$(_json_get queue_position "$body")"

    # Letter grade from numeric score.
    letter_grade="null"
    if [ -n "$overall_score" ] && [ "$overall_score" -eq "$overall_score" ] 2>/dev/null; then
      if   [ "$overall_score" -ge 90 ]; then letter_grade='"A"'
      elif [ "$overall_score" -ge 80 ]; then letter_grade='"B"'
      elif [ "$overall_score" -ge 70 ]; then letter_grade='"C"'
      elif [ "$overall_score" -ge 55 ]; then letter_grade='"D"'
      else letter_grade='"F"'
      fi
    fi

    # Emit a JSON scalar (number, quoted string, or null).
    _jval() {  # $1 = raw value
      local v="$1"
      if [ -z "$v" ]; then
        printf 'null'
      elif [ "$v" -eq "$v" ] 2>/dev/null; then
        printf '%s' "$v"
      else
        printf '"%s"' "$v"
      fi
    }

    local out
    out="$(printf '{%s}' \
      '"id":'"$(_jval "$id")"',"package_id":"'"$pkg"'","status":"'"$status"'","current_scan_status":'"$(_jval "$current_scan_status")"',"overall_score":'"$(_jval "$overall_score")"',"letter_grade":'"$letter_grade"',"completed_at":'"$(_jval "$completed_at")"',"platform":"'"$platform"'","scan_type":"'"$scan_type"'","progress_message":'"$(_jval "$progress_message")"',"total_findings_count":'"$(_jval "$total_findings")"',"critical_findings_count":'"$(_jval "$critical_findings")"',"high_findings_count":'"$(_jval "$high_findings")"',"medium_findings_count":'"$(_jval "$medium_findings")"',"low_findings_count":'"$(_jval "$low_findings")"',"info_findings_count":'"$(_jval "$info_findings")"',"recommendation":'"$(_jval "$recommendation")"',"current_stage":'"$(_jval "$current_stage")"',"queue_position":'"$(_jval "$queue_position")"
    )"
    emit_json "$out"
  fi

  # Human summary to stderr (never reaches Claude's output channel). When polling
  # a specific scan the top-level status IS the live status; otherwise report the
  # completed scan and flag any background rescan via current_scan_status.
  local status_val cur_val stage_val qpos_val score_val
  status_val="$(_json_get status "$body")"
  cur_val="$(_json_get current_scan_status "$body")"
  stage_val="$(_json_get current_stage "$body")"
  qpos_val="$(_json_get queue_position "$body")"
  case "$status_val" in
    completed)
      score_val="$(_json_get overall_score "$body")"
      # Only when THIS was a plain (no-selector) call and a rescan is running,
      # resolve the in-flight scan id and hand back the exact poll command.
      if [ -z "$scan_id" ] && [ -z "$scan_number" ] && [ -n "$cur_val" ] \
         && { [ "$cur_val" = "queued" ] || [ "$cur_val" = "analyzing" ]; }; then
        local infl_id; infl_id="$(_status_inflight_scan_id "$enc")"
        emit_err "citt status: ${pkg} — completed (score: ${score_val:-n/a}); a rescan is ${cur_val} in the background."
        if [ -n "$infl_id" ]; then
          emit_err "Poll the running scan with: citt status ${pkg} --scan-id ${infl_id}"
        else
          emit_err "Poll the running scan with: citt status ${pkg} --scan-id <scan_id> (see: citt status --help)"
        fi
      else
        emit_err "citt status: ${pkg} — completed (score: ${score_val:-n/a})"
      fi
      ;;
    queued)
      if [ -n "$qpos_val" ]; then
        emit_err "citt status: ${pkg} — queued (position ${qpos_val})"
      else
        emit_err "citt status: ${pkg} — queued"
      fi
      ;;
    analyzing)
      emit_err "citt status: ${pkg} — analyzing${stage_val:+ (${stage_val})}"
      ;;
    failed)
      emit_err "citt status: ${pkg} — failed"
      ;;
    *)
      emit_err "citt status: ${pkg} — ${status_val:-unknown}"
      ;;
  esac
}
