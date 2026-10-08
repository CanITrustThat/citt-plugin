#!/usr/bin/env bash
# lib/cmd-app.sh: citt app.
# shellcheck shell=bash disable=SC2034

cmd_app() {
  local platform=android out="" pkg="" n
  while [ $# -gt 0 ]; do
    take_project_flag "$@"
    n=$?
    if [ "$n" -gt 0 ]; then
      shift "$n"
      continue
    fi
    case "$1" in
      --platform)
        need_value "$1" $#
        platform="$2"
        shift
        ;;
      --out)
        need_value "$1" $#
        out="$2"
        shift
        ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        help_app
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
  check_project_flags optional
  [ -n "$pkg" ] || usage_error "give the PACKAGE"
  case "$platform" in android | ios) ;; *) usage_error "--platform is android or ios" ;; esac
  need_auth
  resolve_project
  E_KIND=app
  E_PACKAGE="$pkg"
  call GET "$CITT_V1/projects/$PROJECT_ID/apps/$(urlenc "$pkg")$(query platform "$platform")"
  if [ -n "$out" ]; then
    cp "$RESP" "$out" 2>/dev/null || die 1 "cannot write $out"
    printf 'Wrote %s (%s bytes, sha256 %s)\n' "$out" "$(file_bytes "$out")" "$(sha256_of "$out")"
    return 0
  fi
  if [ "$CITT_JSON" = 1 ]; then
    cat "$RESP"
    return 0
  fi
  jq -r '
    def sev: ["critical", "high", "medium", "low", "info"];
    def cut($n): if length > $n then .[0:$n] + "..." else . end;
    .app as $a | .scan as $s | (.findings // []) as $f
    | "\($a.package_id) \($a.version_name // "-") (versionCode \($a.version_code // "-")), \($a.title // "-")"
      + (if ($a.developer | type) == "object" then " by \($a.developer.name // "-")"
         elif ($a.developer | type) == "string" then " by \($a.developer)" else "" end),
      "Scan \($s.scan_id // "-"): \(if $s.deep then "deep" else "fast" end), rule pack \(($s.rulepack_sha256 // "-") | .[0:8])..., \($s.finished_at // "-")",
      "Compliance:",
      ((.compliance // [])[] | "  \(.regime)  \(.status)  \(.statement // "" | cut(100))"),
      "Facts: " + ([(.facts // {}) | to_entries[] | select(.value | type == "array") | "\(.key) \(.value | length)"] | join(", ")),
      "Findings: \($f | length) (" + ([sev[] as $v | ($f | map(select(.severity == $v)) | length) as $c | select($c > 0) | "\($v) \($c)"] | join(", ")) + ")",
      ($f | map(select(.severity != "info")) | sort_by(.severity as $v | sev | index($v))[]
        | "  \(.severity)  \(.rule_id // .source)  \(.subject | cut(40))  \(.finding_id)")' "$RESP" \
    || die 1 "unparseable per-app JSON"
}
