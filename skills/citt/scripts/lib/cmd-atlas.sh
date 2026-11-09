#!/usr/bin/env bash
# lib/cmd-atlas.sh: citt atlas-app, atlas-sdk, atlas-cluster, atlas-search (NP-1481).
# The commands call the CITT backend's /api/research/v1/atlas/* routes (plugin -> backend -> navigator ->
# citt-atlas). They reuse the stored token and inherit the backend's atlas_enabled gate: no new
# credential surface. A 403 atlas_not_enabled prints the fixed CITT_ATLAS_DISABLED_LINE (common.sh);
# a 200 { "atlas_available": false } is the backend's graceful-degrade state and prints the
# unavailable line (feedback-no-dead-ends). Contract: docs/atlas/api-plan/API-CONTRACT-v1.md.
# shellcheck shell=bash disable=SC2034,SC2016

CITT_ATLAS_BASE="$CITT_V1/atlas"

# atlas_unavailable: the backend returned 200 { atlas_available:false, reason, retry_after }. Prints
# the unavailable line (no internal mechanism name) and exits 8; with --json emits the body.
atlas_unavailable() {
  local reason retry msg
  reason="$(body_field '.reason')"
  retry="$(body_field '.retry_after')"
  case "$reason" in
    timeout) msg="atlas data unavailable, try again shortly (the service did not answer in time)" ;;
    unreachable) msg="atlas data unavailable, try again shortly (the service could not be reached)" ;;
    rate_limited) msg="atlas data unavailable, too many requests" ;;
    *) msg="atlas data unavailable, try again shortly" ;;
  esac
  if is_uint "$retry" && [ "$retry" -gt 0 ]; then msg="$msg; retry in $retry s"; fi
  fail_out 8 "$msg"
}

# atlas_call METHOD PATH: a GET to the backend atlas surface, then the degrade check. E_KIND=atlas
# keeps a 404 on an undeployed route as the "update the plugin" line.
atlas_call() {
  E_KIND=atlas
  call "$@"
  if jq -e '.atlas_available == false' "$RESP" >/dev/null 2>&1; then
    atlas_unavailable
  fi
}

# _atlas_fresh ISO: a trailing "atlas data as of <local time>" line, nothing when ISO is empty/null.
_atlas_fresh() {
  local iso="$1" e
  [ -n "$iso" ] && [ "$iso" != null ] || return 0
  e="$(jq -rn --arg t "$iso" 'try ($t | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601) catch empty' 2>/dev/null)"
  [ -n "$e" ] || return 0
  printf 'atlas data as of %s\n' "$(local_time "$e")"
}

# _atlas_pager PATH: fetches one page, or every page under $ATLAS_ALL, into $ATLAS_DATA (a JSON array
# of the accumulated data items). Reads the fixed query from the $ATLAS_QS array plus $ATLAS_LIMIT
# and $ATLAS_CURSOR. Sets ATLAS_META (first page's meta), ATLAS_SNAP (freshness), ATLAS_NEXT (the
# last next_cursor). Needs: ATLAS_QS set (possibly empty), ATLAS_ALL, ATLAS_LIMIT, ATLAS_CURSOR.
_atlas_pager() {
  local path="$1" cursor="$ATLAS_CURSOR" pages=0 q
  ATLAS_DATA="$(tmpfile atlas_data)"
  printf '[]' >"$ATLAS_DATA"
  ATLAS_META=""
  ATLAS_SNAP=""
  ATLAS_NEXT=""
  while :; do
    q="$(query ${ATLAS_QS[@]+"${ATLAS_QS[@]}"} limit "$ATLAS_LIMIT" cursor "$cursor")"
    atlas_call GET "$path$q"
    jq -e '.data | type == "array"' "$RESP" >/dev/null 2>&1 || die 1 "unexpected response from the server"
    jq -c --slurpfile p "$RESP" '. + $p[0].data' "$ATLAS_DATA" >"$ATLAS_DATA.n" && mv "$ATLAS_DATA.n" "$ATLAS_DATA"
    [ -n "$ATLAS_META" ] || ATLAS_META="$(jq -c '.meta // {}' "$RESP")"
    ATLAS_SNAP="$(body_field '.snapshot.matview_refreshed_at')"
    ATLAS_NEXT="$(jq -r '.page.next_cursor // empty' "$RESP")"
    cursor="$ATLAS_NEXT"
    pages=$((pages + 1))
    if [ "$ATLAS_ALL" != 1 ] || [ -z "$cursor" ] || [ "$pages" -ge 200 ]; then
      break
    fi
  done
}

# _atlas_list_json: the reconstructed list envelope from the accumulated pages, for --json.
_atlas_list_json() {
  jq -c -n --slurpfile d "$ATLAS_DATA" --argjson meta "${ATLAS_META:-{\}}" \
    --arg nc "$ATLAS_NEXT" --arg snap "${ATLAS_SNAP:-}" \
    '{data: $d[0], meta: $meta,
      page: {next_cursor: (if $nc == "" then null else $nc end)},
      snapshot: {source: "atlas.meta", matview_refreshed_at: (if $snap == "" then null else $snap end)}}'
}

# _atlas_more CMD: the "More:" cursor line for a page that has a next_cursor (human output).
_atlas_more() {
  [ -z "$ATLAS_NEXT" ] || printf 'More: %s --cursor %s\n' "$1" "$ATLAS_NEXT"
}

# _atlas_empty_reason: for an empty list, the reason and next action from meta (no dead end). True
# (prints and returns 0) when the data array is empty.
_atlas_empty_reason() {
  [ "$(jq 'length' "$ATLAS_DATA")" = 0 ] || return 1
  local reason next
  reason="$(printf '%s' "${ATLAS_META:-{}}" | jq -r '.reason // empty')"
  next="$(printf '%s' "${ATLAS_META:-{}}" | jq -r '.next_action // empty')"
  printf 'no atlas results%s\n' "${reason:+ ($reason)}"
  [ -z "$next" ] || printf 'next: %s\n' "$next"
  return 0
}

# --- citt atlas-app ----------------------------------------------------------------------------

cmd_atlas_app() {
  local pkg="" tab="" all=0 limit="" cursor=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --sdks) tab=sdks ;;
      --clusters) tab=clusters ;;
      --all) all=1 ;;
      --limit)
        need_value "$1" $#
        limit="$2"
        shift
        ;;
      --cursor)
        need_value "$1" $#
        cursor="$2"
        shift
        ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_atlas_app
        exit 0
        ;;
      -*) usage_error "unknown option $1" ;;
      *)
        [ -z "$pkg" ] || usage_error "one PACKAGE only"
        pkg="$1"
        ;;
    esac
    shift
  done
  [ -n "$pkg" ] || usage_error "give the PACKAGE"
  [ -z "$tab" ] || [ -z "$limit" ] || is_uint "$limit" || usage_error "--limit needs a number"
  need_auth

  if [ -z "$tab" ]; then
    atlas_call GET "$CITT_ATLAS_BASE/apps/$(urlenc "$pkg")"
    if [ "$CITT_JSON" = 1 ]; then
      cat "$RESP"
      printf '\n'
      return 0
    fi
    jq -r '
      .data as $d | ($d.store // null) as $s |
      ($d.package
        + (if $s then "  " + ($s.title // "-")
             + (if ($s.developer // "") != "" then " by \($s.developer)" else "" end)
             + "  (\($s.category // "-"), \($s.installs // "-"))" else "" end)),
      (if $s and ([$s.developer_email, $s.developer_website, $s.developer_link]
                  | map(select(. != null and . != "")) | length > 0)
        then "contact: " + ([$s.developer_email, $s.developer_website, $s.developer_link]
                            | map(select(. != null and . != "")) | join("  "))
        else empty end),
      (if $d.has_analysis == false
        then ("no atlas analysis" + (if ($d.reason // "") != "" then " (\($d.reason))" else "" end))
        else empty end),
      (if ($d.sdks // []) | length > 0 then "SDKs (\($d.sdks | length)):" else empty end),
      (($d.sdks // [])[] | "  \(.category // "(uncategorized)")  \(.name)  \(.confidence // "-")"),
      (if ($d.clusters // []) | length > 0 then "Clusters (\($d.clusters | length)):" else empty end),
      (($d.clusters // []) | sort_by(if .hidden_network then 0 else 1 end)[]
        | "  \(if .hidden_network then "hidden-network" else "-" end)  \(.term)  \(.value)  \(.app_count) apps, \(.developer_count) developers"),
      (if $d.has_analysis == false and (($d.next_action // "") != "") then "next: \($d.next_action)" else empty end)
    ' "$RESP" || die 1 "unparseable atlas response"
    _atlas_fresh "$(body_field '.snapshot.matview_refreshed_at')"
    return 0
  fi

  # A tab: the full paged SDK or cluster list.
  ATLAS_QS=()
  ATLAS_ALL="$all"
  ATLAS_LIMIT="$limit"
  ATLAS_CURSOR="$cursor"
  _atlas_pager "$CITT_ATLAS_BASE/apps/$(urlenc "$pkg")/$tab"
  if [ "$CITT_JSON" = 1 ]; then
    _atlas_list_json
    return 0
  fi
  if _atlas_empty_reason; then return 0; fi
  if [ "$tab" = sdks ]; then
    jq -r '.[] | "  \(.category // "(uncategorized)")  \(.name)  \(.confidence // "-")"' "$ATLAS_DATA"
  else
    jq -r 'sort_by(if .hidden_network then 0 else 1 end)[]
      | "  \(if .hidden_network then "hidden-network" else "-" end)  \(.term)  \(.value)  \(.app_count) apps, \(.developer_count) developers"' "$ATLAS_DATA"
  fi
  _atlas_fresh "$ATLAS_SNAP"
  _atlas_more "citt atlas-app $(shq "$pkg") --$tab"
}

# --- citt atlas-sdk ----------------------------------------------------------------------------

cmd_atlas_sdk() {
  local name="" apps=0 category="" installs_min="" all=0 limit="" cursor=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --apps) apps=1 ;;
      --category)
        need_value "$1" $#
        category="$2"
        shift
        ;;
      --installs-min)
        need_value "$1" $#
        installs_min="$2"
        shift
        ;;
      --all) all=1 ;;
      --limit)
        need_value "$1" $#
        limit="$2"
        shift
        ;;
      --cursor)
        need_value "$1" $#
        cursor="$2"
        shift
        ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_atlas_sdk
        exit 0
        ;;
      -*) usage_error "unknown option $1" ;;
      *)
        [ -z "$name" ] || usage_error "one SDK NAME only"
        name="$1"
        ;;
    esac
    shift
  done
  [ -n "$name" ] || usage_error "give the SDK NAME"
  if [ "$apps" = 0 ] && { [ -n "$category" ] || [ -n "$installs_min" ]; }; then
    usage_error "--category and --installs-min go with --apps"
  fi
  [ -z "$installs_min" ] || is_uint "$installs_min" || usage_error "--installs-min needs a number"
  [ -z "$limit" ] || is_uint "$limit" || usage_error "--limit needs a number"
  need_auth
  ATLAS_ALL="$all"
  ATLAS_LIMIT="$limit"
  ATLAS_CURSOR="$cursor"

  if [ "$apps" = 0 ]; then
    # The SDK's corpus counts from the catalog, matched by name.
    ATLAS_QS=(q "$name")
    _atlas_pager "$CITT_ATLAS_BASE/sdks"
    if [ "$CITT_JSON" = 1 ]; then
      _atlas_list_json
      return 0
    fi
    if _atlas_empty_reason; then return 0; fi
    jq -r '.[] | "  \(.name)  \(.category // "(uncategorized)")  \(.build_count // 0) builds, \(.app_count // 0) apps"' "$ATLAS_DATA"
    _atlas_fresh "$ATLAS_SNAP"
    _atlas_more "citt atlas-sdk $(shq "$name")"
    return 0
  fi

  ATLAS_QS=(category "$category" installs_min "$installs_min")
  _atlas_pager "$CITT_ATLAS_BASE/sdks/$(urlenc "$name")/apps"
  if [ "$CITT_JSON" = 1 ]; then
    _atlas_list_json
    return 0
  fi
  if _atlas_empty_reason; then return 0; fi
  jq -r '.[] | "  \(.package)  \(.title // "-")"
    + (if (.developer // "") != "" then " by \(.developer)" else "" end)
    + "  (\(.category // "-"), \(.installs // "-"))  \(.confidence // "-")"' "$ATLAS_DATA"
  _atlas_fresh "$ATLAS_SNAP"
  _atlas_more "citt atlas-sdk $(shq "$name") --apps"
}

# --- citt atlas-cluster ------------------------------------------------------------------------

cmd_atlas_cluster() {
  local id="" hidden=0 all=0 limit="" cursor=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --hidden-network) hidden=1 ;;
      --all) all=1 ;;
      --limit)
        need_value "$1" $#
        limit="$2"
        shift
        ;;
      --cursor)
        need_value "$1" $#
        cursor="$2"
        shift
        ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_atlas_cluster
        exit 0
        ;;
      -*) usage_error "unknown option $1" ;;
      *)
        [ -z "$id" ] || usage_error "one cluster ID only"
        id="$1"
        ;;
    esac
    shift
  done
  [ -z "$limit" ] || is_uint "$limit" || usage_error "--limit needs a number"
  need_auth
  ATLAS_ALL="$all"
  ATLAS_LIMIT="$limit"
  ATLAS_CURSOR="$cursor"

  if [ "$hidden" = 1 ]; then
    [ -z "$id" ] || usage_error "--hidden-network lists the family; drop the cluster ID"
    ATLAS_QS=(hidden_network true)
    _atlas_pager "$CITT_ATLAS_BASE/clusters"
    if [ "$CITT_JSON" = 1 ]; then
      _atlas_list_json
      return 0
    fi
    if _atlas_empty_reason; then return 0; fi
    jq -r '.[] | "  \(.term)  \(.value)  \(.app_count) apps, \(.developer_count) developers"' "$ATLAS_DATA"
    _atlas_fresh "$ATLAS_SNAP"
    _atlas_more "citt atlas-cluster --hidden-network"
    return 0
  fi

  [ -n "$id" ] || usage_error "give the cluster ID, or --hidden-network for the family"
  # The cluster head, then its member apps.
  atlas_call GET "$CITT_ATLAS_BASE/clusters/$(urlenc "$id")"
  local head
  head="$(tmpfile atlas_cluster)"
  cp "$RESP" "$head"
  ATLAS_QS=()
  _atlas_pager "$CITT_ATLAS_BASE/clusters/$(urlenc "$id")/apps"
  if [ "$CITT_JSON" = 1 ]; then
    jq -c -n --slurpfile h "$head" --slurpfile a "$ATLAS_DATA" --arg nc "$ATLAS_NEXT" \
      '{data: $h[0].data, apps: $a[0],
        page: {next_cursor: (if $nc == "" then null else $nc end)},
        snapshot: $h[0].snapshot, generated_at: $h[0].generated_at}'
    return 0
  fi
  # A well-formed id for a (term, value) not in the matview returns data null-shaped with a reason
  # (contract "no dead ends"): print the reason and next action rather than an empty cluster.
  if jq -e '(.data == null) or ((.data.term // null) == null)' "$head" >/dev/null 2>&1; then
    jq -r '"no atlas cluster for this id"
      + (if ((.data.reason // "") != "") then " (\(.data.reason))" else "" end),
      (if ((.data.next_action // "") != "") then "next: \(.data.next_action)" else empty end)' "$head"
    _atlas_fresh "$(jq -r '.snapshot.matview_refreshed_at // empty' "$head")"
    return 0
  fi
  jq -r '.data
    | "cluster \(.term)  \(.value)",
      "\(.app_count) apps, \(.developer_count) developers"
      + (if .hidden_network then "  [hidden-network]" else "" end)
      + (if .is_placeholder then "  [placeholder]" else "" end)
      + (if .is_fingerprint then "  [fingerprint]" else "" end)' "$head" \
    || die 1 "unparseable atlas response"
  if [ "$(jq 'length' "$ATLAS_DATA")" != 0 ]; then
    printf 'Apps:\n'
    jq -r '.[] | "  \(.package)  \(.title // "-")"
      + (if (.developer // "") != "" then " by \(.developer)" else "" end)' "$ATLAS_DATA"
  fi
  _atlas_fresh "$ATLAS_SNAP"
  _atlas_more "citt atlas-cluster $(shq "$id")"
}

# --- citt atlas-search -------------------------------------------------------------------------

cmd_atlas_search() {
  local query="" all=0 limit="" cursor=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) all=1 ;;
      --limit)
        need_value "$1" $#
        limit="$2"
        shift
        ;;
      --cursor)
        need_value "$1" $#
        cursor="$2"
        shift
        ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_atlas_search
        exit 0
        ;;
      -*) usage_error "unknown option $1" ;;
      *)
        [ -z "$query" ] || usage_error "one QUERY only (quote a multi-word query)"
        query="$1"
        ;;
    esac
    shift
  done
  [ -n "$query" ] || usage_error "give the QUERY"
  [ -z "$limit" ] || is_uint "$limit" || usage_error "--limit needs a number"
  need_auth
  ATLAS_QS=(q "$query")
  ATLAS_ALL="$all"
  ATLAS_LIMIT="$limit"
  ATLAS_CURSOR="$cursor"
  _atlas_pager "$CITT_ATLAS_BASE/search"
  if [ "$CITT_JSON" = 1 ]; then
    _atlas_list_json
    return 0
  fi
  if _atlas_empty_reason; then return 0; fi
  jq -r '.[] | "\(.package)  \(.title // "-")"
    + (if (.developer // "") != "" then " by \(.developer)" else "" end)
    + "  (\(.category // "-"), \(.installs // "-"))  "
    + (if .has_analysis then "analysis" else "no analysis" end)
    + (if (.match_field // "") != "" then "  match:\(.match_field)" else "" end)' "$ATLAS_DATA"
  _atlas_fresh "$ATLAS_SNAP"
  _atlas_more "citt atlas-search $(shq "$query")"
}
