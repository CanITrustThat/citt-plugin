#!/usr/bin/env bash
# =============================================================================
# lib/cmd-results.sh — citt results <pkg>  (CITT-335)
# =============================================================================
# Public subcommand: fetch the richer PUBLIC scorecard data for a package so
# Claude can reason over it (verdict, summaries, top issues, scores, scan
# history).  No authentication required — uses _curl_pub_get.
# Even if a token is stored it NEVER leaks to stdout/argv/xtrace.
#
# Usage (via dispatcher):   citt results <package_id>
# Direct source + call:     . lib/cmd-results.sh; citt_cmd_results com.example.app
#
# Two API calls (both public, no token):
#   GET /api/status/{pkg}         — primary: StatusResponse (api.py:637,1970)
#   GET /api/apps/{pkg}/scans     — secondary: ScanListResponse (api.py:6641)
#                                   (public scans only for unauthenticated callers)
#
# Emits compact JSON to stdout for Claude containing ONLY real fields from
# StatusResponse (verified at api.py:637) and ScanListResponse (api.py:5842):
#   package_id, app_name, status, overall_score, letter_grade,
#   security_score, privacy_score, recommendation, what_it_means_for_you,
#   quick_verdict {best_for, avoid_if}, top_security_issues, top_privacy_issues,
#   findings_by_category [{category, critical, high, medium, low}],
#   total_findings_count, completed_at, platform, store_url,
#   stamps [{stamp_id, state, ...}], red_flags [{...}],
#   scans [{scan_id, scan_number, status, overall_score, version, completed_at}]
#
# Gating note (api.py:2082-2110): raw per-severity counts + raw findings[] are
# OWNER-ONLY for completed scans.  Public callers get total_findings_count and
# findings_by_category.  This command surfaces exactly what the API returns
# without requesting auth, so it faithfully represents what an anonymous reader
# can see.
#
# Clean states:
#   completed  — full result JSON with verdict + issues
#   pending    — partial JSON with status + progress (no verdict yet)
#   not-found  — exits non-zero with {"error":"not_found",...}
#
# Dispatcher contract (scripts/citt):
#   Sources lib/citt-common.sh first, then sources this file and calls
#   citt_cmd_results "$@".
# =============================================================================

citt_cmd_results() {
  local pkg="${1:-}"
  if [ -z "$pkg" ]; then
    emit_err "usage: citt results <package_id>"
    exit 2
  fi

  # URL-encode the package id.
  local enc
  if command -v python3 >/dev/null 2>&1; then
    enc="$(python3 -c 'import sys,urllib.parse; sys.stdout.write(urllib.parse.quote(sys.argv[1], safe=""))' "$pkg" 2>/dev/null)" || enc="$pkg"
  else
    enc="$pkg"
  fi

  # -------------------------------------------------------------------------
  # 1. Primary call: GET /api/status/{pkg}
  # -------------------------------------------------------------------------
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
      emit_err "citt results: package '${pkg}' not found"
      exit 1
      ;;
    "")
      emit_err "citt results: could not reach the CITT API"
      exit 1
      ;;
    *)
      emit_err "citt results: unexpected HTTP ${code} from /api/status/${pkg}"
      exit 1
      ;;
  esac

  # Capture the primary body before making the second call (which overwrites
  # _CITT_RESP_FILE).
  local primary_body
  primary_body="$(cat "${_CITT_RESP_FILE}" 2>/dev/null || true)"

  # -------------------------------------------------------------------------
  # 2. Secondary call: GET /api/apps/{pkg}/scans  (scan history)
  #    Non-fatal — if this fails we emit an empty list.
  # -------------------------------------------------------------------------
  local scans_body=""
  local scans_code
  scans_code="$(_curl_pub_get "/api/apps/${enc}/scans")"
  if [ "$scans_code" = "200" ]; then
    scans_body="$(cat "${_CITT_RESP_FILE}" 2>/dev/null || true)"
  fi

  # -------------------------------------------------------------------------
  # 3. Assemble the result JSON.
  # -------------------------------------------------------------------------
  if command -v jq >/dev/null 2>&1; then
    # jq path — full structured output.
    # letter_grade: A=90+, B=80-89, C=70-79, D=55-69, F=<55 (null when no score).
    local out
    out="$(
      printf '%s' "$primary_body" | jq -c \
        --argjson scans_body "$(printf '%s' "${scans_body:-null}")" '
        def grade(s):
          if s == null then null
          elif s >= 90 then "A"
          elif s >= 80 then "B"
          elif s >= 70 then "C"
          elif s >= 55 then "D"
          else "F"
          end;
        def scan_summary:
          {
            scan_id:       .scan_id,
            scan_number:   .scan_number,
            status:        .status,
            scan_type:     (.scan_type // "full"),
            overall_score: .overall_score,
            version:       .version,
            analysis_date: .analysis_date,
            submitted_at:  .submitted_at,
            completed_at:  .completed_at,
            is_private:    .is_private
          };
        {
          package_id:             .package_id,
          app_name:               .app_name,
          developer_name:         .developer_name,
          status:                 .status,
          platform:               (.platform // "android"),
          overall_score:          .overall_score,
          letter_grade:           (grade(.overall_score)),
          security_score:         .security_score,
          privacy_score:          .privacy_score,
          completed_at:           .completed_at,
          submitted_at:           .submitted_at,
          progress_message:       .progress_message,
          current_stage:          .current_stage,
          recommendation:         .recommendation,
          what_it_means_for_you:  .what_it_means_for_you,
          quick_verdict:          .quick_verdict,
          top_security_issues:    .top_security_issues,
          top_privacy_issues:     .top_privacy_issues,
          findings_by_category:   .findings_by_category,
          total_findings_count:   .total_findings_count,
          primary_concern:        .primary_concern,
          third_party_services:   .third_party_services,
          strengths:              .strengths,
          context_tags:           .context_tags,
          stamps:                 .stamps,
          red_flags:              .red_flags,
          stamps_status:          .stamps_status,
          trust_verdict:          .trust_verdict,
          store_url:              .store_url,
          public_report_url:      .public_report_url,
          version:                .version,
          analysis_date:          .analysis_date,
          disclosure_status:      .disclosure_status,
          scans: (
            if ($scans_body != null and ($scans_body | type) == "object")
            then [ $scans_body.scans[]? | scan_summary ]
            else []
            end
          )
        }
      ' 2>/dev/null
    )"
    if [ -z "$out" ]; then
      emit_err "citt results: failed to parse response"
      exit 1
    fi
    emit_json "$out"
  else
    # No-jq fallback: surface the key scalar fields that Claude most needs.
    local status app_name overall_score completed_at platform progress_message
    local recommendation what_it_means recommendation_msg

    status="$(_json_get status "$primary_body")"
    app_name="$(_json_get app_name "$primary_body")"
    overall_score="$(_json_get overall_score "$primary_body")"
    completed_at="$(_json_get completed_at "$primary_body")"
    platform="$(_json_get platform "$primary_body")"; [ -z "$platform" ] && platform="android"
    progress_message="$(_json_get progress_message "$primary_body")"
    recommendation="$(_json_get recommendation "$primary_body")"
    what_it_means="$(_json_get what_it_means_for_you "$primary_body")"

    # Compute letter grade.
    local letter_grade="null"
    if [ -n "$overall_score" ] && [ "$overall_score" -eq "$overall_score" ] 2>/dev/null; then
      if   [ "$overall_score" -ge 90 ]; then letter_grade='"A"'
      elif [ "$overall_score" -ge 80 ]; then letter_grade='"B"'
      elif [ "$overall_score" -ge 70 ]; then letter_grade='"C"'
      elif [ "$overall_score" -ge 55 ]; then letter_grade='"D"'
      else letter_grade='"F"'
      fi
    fi

    _jval() {
      local v="$1"
      if [ -z "$v" ]; then
        printf 'null'
      elif [ "$v" -eq "$v" ] 2>/dev/null; then
        printf '%s' "$v"
      else
        # Escape quotes in string values for safe JSON embedding.
        printf '"%s"' "$(printf '%s' "$v" | sed 's/"/\\"/g')"
      fi
    }

    local out
    out="$(printf '{%s}' \
      '"package_id":"'"$pkg"'","app_name":'"$(_jval "$app_name")"',"status":"'"$status"'","platform":"'"$platform"'","overall_score":'"$(_jval "$overall_score")"',"letter_grade":'"$letter_grade"',"completed_at":'"$(_jval "$completed_at")"',"progress_message":'"$(_jval "$progress_message")"',"recommendation":'"$(_jval "$recommendation")"',"what_it_means_for_you":'"$(_jval "$what_it_means")"',"scans":[]'
    )"
    emit_json "$out"
  fi

  # Human summary on stderr.
  local status_val
  status_val="$(_json_get status "$primary_body")"
  case "$status_val" in
    completed)
      local score; score="$(_json_get overall_score "$primary_body")"
      emit_err "citt results: ${pkg} — completed (score: ${score:-n/a})"
      ;;
    failed)
      emit_err "citt results: ${pkg} — failed"
      ;;
    *)
      emit_err "citt results: ${pkg} — ${status_val:-unknown} (results not yet available)"
      ;;
  esac
}
