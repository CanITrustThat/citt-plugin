#!/usr/bin/env bash
# lib/cmd-status.sh — citt status <package_id>. Public subcommand, no auth
# (uses _curl_pub_get; any stored token never leaks to stdout/argv/xtrace).
# Emits compact status JSON to stdout (package_id, status, overall_score,
# letter_grade, completed_at, platform, severity counts, progress_message);
# not-found exits non-zero with {"error":"not_found",...}.

citt_cmd_status() {
  local pkg="${1:-}"
  if [ -z "$pkg" ]; then
    emit_err "usage: citt status <package_id>"
    exit 2
  fi

  # URL-encode the package id (defensive; ids are [A-Za-z0-9._-]).
  local enc
  if command -v python3 >/dev/null 2>&1; then
    enc="$(python3 -c 'import sys,urllib.parse; sys.stdout.write(urllib.parse.quote(sys.argv[1], safe=""))' "$pkg" 2>/dev/null)" || enc="$pkg"
  else
    enc="$pkg"
  fi

  # Public GET; _curl_pub_get writes body to _CITT_RESP_FILE.
  local code
  code="$(_curl_pub_get "/api/status/${enc}")"

  case "$code" in
    200)
      : # handled below
      ;;
    404)
      local out
      if command -v jq >/dev/null 2>&1; then
        out="$(jq -c --arg pkg "$pkg" '{"error":"not_found","package_id":$pkg,"detail":(.detail // "Package not found")}' "${_CITT_RESP_FILE}" 2>/dev/null \
          || printf '{"error":"not_found","package_id":"%s"}' "$pkg")"
      else
        out="$(printf '{"error":"not_found","package_id":"%s"}' "$pkg")"
      fi
      emit_json "$out"
      emit_err "citt status: package '${pkg}' not found"
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
        package_id:           .package_id,
        status:               .status,
        overall_score:        .overall_score,
        letter_grade:         (grade(.overall_score)),
        completed_at:         .completed_at,
        platform:             (.platform // "android"),
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
    local status overall_score completed_at platform progress_message
    local total_findings critical_findings high_findings medium_findings low_findings info_findings
    local recommendation current_stage queue_position letter_grade

    status="$(_json_get status "$body")"
    overall_score="$(_json_get overall_score "$body")"
    completed_at="$(_json_get completed_at "$body")"
    platform="$(_json_get platform "$body")"; [ -z "$platform" ] && platform="android"
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
      '"package_id":"'"$pkg"'","status":"'"$status"'","overall_score":'"$(_jval "$overall_score")"',"letter_grade":'"$letter_grade"',"completed_at":'"$(_jval "$completed_at")"',"platform":"'"$platform"'","progress_message":'"$(_jval "$progress_message")"',"total_findings_count":'"$(_jval "$total_findings")"',"critical_findings_count":'"$(_jval "$critical_findings")"',"high_findings_count":'"$(_jval "$high_findings")"',"medium_findings_count":'"$(_jval "$medium_findings")"',"low_findings_count":'"$(_jval "$low_findings")"',"info_findings_count":'"$(_jval "$info_findings")"',"recommendation":'"$(_jval "$recommendation")"',"current_stage":'"$(_jval "$current_stage")"',"queue_position":'"$(_jval "$queue_position")"
    )"
    emit_json "$out"
  fi

  # Human summary to stderr (never reaches Claude's output channel).
  local status_val
  status_val="$(_json_get status "$body")"
  case "$status_val" in
    completed)
      local score; score="$(_json_get overall_score "$body")"
      emit_err "citt status: ${pkg} — completed (score: ${score:-n/a})"
      ;;
    failed)
      emit_err "citt status: ${pkg} — failed"
      ;;
    *)
      emit_err "citt status: ${pkg} — ${status_val:-unknown}"
      ;;
  esac
}
