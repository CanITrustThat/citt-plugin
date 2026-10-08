#!/usr/bin/env bash
# lib/cmd-export.sh: citt export-results and citt export-sources.
# The zip is checked against the export's sha256, every entry name is checked, the files are
# extracted under .downloads/<id>.tmp and verified against manifest.json, and only then moved
# into DESIGN-11's local layout.
# shellcheck shell=bash disable=SC2034

# slug NAME: lowercased, every run outside [a-z0-9] replaced by "-".
slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9][^a-z0-9]*/-/g'
}

# _reject ID NAME: an unsafe entry; removes what was extracted and exits 11.
_reject() {
  rm -rf "$DL/$1.tmp" 2>/dev/null
  die 11 "export $1 rejected: unsafe entry name $2"
}

# _unsafe_name NAME: true when the name is absolute, has a backslash or a ".." segment.
_unsafe_name() {
  case "$1" in
    /* | *\\* | '' ) return 0 ;;
  esac
  case "/$1/" in */../* | */./*) return 0 ;; esac
  return 1
}

# _check_entries ID ZIP MANIFEST: every entry is manifest.json, SHA256SUMS or a file the
# manifest lists, once, as a regular file with a safe name.
_check_entries() {
  local id="$1" zip="$2" man="$3" names listed name
  names="$(tmpfile names)"
  listed="$(tmpfile listed)"
  unzip -Z1 "$zip" >"$names" 2>/dev/null || die 11 "export $id rejected: the zip cannot be listed"
  while IFS= read -r name; do
    _unsafe_name "$name" && _reject "$id" "$name"
  done <"$names"
  # Symlink entries: zipinfo mode strings starting with "l".
  name="$(unzip -Z "$zip" 2>/dev/null | awk '/^l/ { $1 = $2 = $3 = $4 = $5 = $6 = $7 = $8 = ""; sub(/^ +/, ""); print; exit }')"
  [ -z "$name" ] || _reject "$id" "$name"
  jq -r '.files[].name' "$man" >"$listed" 2>/dev/null || die 11 "export $id rejected: manifest.json is not valid"
  printf 'manifest.json\nSHA256SUMS\n' >>"$listed"
  while IFS= read -r name; do
    grep -qxF -- "$name" "$listed" || _reject "$id" "$name"
  done <"$names"
  name="$(sort "$names" | uniq -d | head -n1)"
  [ -z "$name" ] || _reject "$id" "$name"
  while IFS= read -r name; do
    _unsafe_name "$name" && _reject "$id" "$name"
  done <"$listed"
}

# _defuse_tree DIR: renames, deepest first, the files and folders an agent loads as instructions
# (CLAUDE.md, AGENTS.md and their variants, .claude/, .codex/, .agents/) to <name>.txt, and appends
# each renamed path, relative to DIR's parent, to $_CITT_TMP/renamed.
_defuse_tree() {
  local dir="$1" p
  find "$dir" -depth -mindepth 1 \( -name CLAUDE.md -o -name CLAUDE.local.md -o -name AGENTS.md -o -name AGENTS.override.md \
    -o \( -type d \( -name .claude -o -name .codex -o -name .agents \) \) \) -print | while IFS= read -r p; do
    mv "$p" "$p.txt" && printf '%s\n' "${p#"$(dirname "$dir")"/}" >>"$_CITT_TMP/renamed"
  done
}

# _check_tar ID TARBALL: regular files and directories with safe names only.
_check_tar() {
  local id="$1" tb="$2" line name
  tar -tzvf "$tb" >"$_CITT_TMP/tarv" 2>/dev/null || die 11 "export $id rejected: a tree tarball cannot be listed"
  while IFS= read -r line; do
    case "$line" in -* | d*) ;; *) _reject "$id" "tree entry: $line" ;; esac
  done <"$_CITT_TMP/tarv"
  tar -tzf "$tb" >"$_CITT_TMP/tarn" 2>/dev/null
  while IFS= read -r name; do
    _unsafe_name "${name%/}" && _reject "$id" "tree entry $name"
  done <"$_CITT_TMP/tarn"
}

# _place STAGE DEST: moves every file of STAGE to the same path under DEST. An identical file
# is left untouched; a different one is replaced and counted in UPDATED.
UPDATED=0
_place() {
  local stage="$1" dest="$2" rel
  (cd "$stage" && find . -type f) | while IFS= read -r rel; do
    rel="${rel#./}"
    if [ -f "$dest/$rel" ]; then
      if [ "$(sha256_of "$dest/$rel")" = "$(sha256_of "$stage/$rel")" ]; then
        continue
      fi
      printf 'u\n' >>"$_CITT_TMP/updated"
    fi
    mkdir -p "$(dirname "$dest/$rel")" || exit 1
    mv -f "$stage/$rel" "$dest/$rel" || exit 1
  done || die 1 "cannot write under $dest"
  UPDATED="$(wc -l <"$_CITT_TMP/updated" 2>/dev/null | tr -d ' ')"
  [ -n "$UPDATED" ] || UPDATED=0
}

cmd_export() {
  local kind="$1" apps="" out="" keep=0 export_id="" timeout=540 n
  shift
  CITT_CMD="citt export-$kind"
  while [ $# -gt 0 ]; do
    take_project_flag "$@"
    n=$?
    if [ "$n" -gt 0 ]; then
      shift "$n"
      continue
    fi
    case "$1" in
      --apps)
        need_value "$1" $#
        apps="$2"
        shift
        ;;
      --out)
        need_value "$1" $#
        out="$2"
        shift
        ;;
      --keep-zip) keep=1 ;;
      --export-id)
        need_value "$1" $#
        export_id="$2"
        shift
        ;;
      --timeout)
        need_value "$1" $#
        timeout="$2"
        shift
        ;;
      --json) CITT_JSON=1 ;;
      --help | -h)
        if [ "$kind" = results ]; then help_export_results; else help_export_sources; fi
        exit 0
        ;;
      *) usage_error "unknown option $1" ;;
    esac
    shift
  done
  check_project_flags
  [ -n "$apps" ] || usage_error "give --apps all or --apps A[,B...]"
  if [ "$kind" = sources ] && [ "$apps" = all ]; then
    usage_error "list the apps; sources exports can be several GB"
  fi
  is_uint "$timeout" || usage_error "--timeout needs a number of seconds"
  if [ -n "$export_id" ] && ! is_uint "$export_id"; then usage_error "--export-id needs a number"; fi
  require_unzip
  need_auth
  resolve_project

  if [ -z "$export_id" ]; then
    local body
    body="$(tmpfile export_body)"
    jq -nc --arg k "$kind" --arg apps "$apps" \
      '{kind: $k, apps: (if $apps == "all" then "all" else ($apps | split(",") | map(select(. != ""))) end)}' >"$body"
    call POST "$CITT_V1/projects/$PROJECT_ID/exports" "$body"
    export_id="$(body_field '.export_id')"
    is_uint "$export_id" || die 1 "unparseable response from POST $CITT_V1/projects/$PROJECT_ID/exports"
  fi
  E_KIND="export"
  E_EXPORT="$export_id"

  # Poll until done or failed.
  local st status start
  st="$(tmpfile export_status)"
  start="$(now_s)"
  while :; do
    call GET "$CITT_V1/exports/$export_id"
    cp "$RESP" "$st"
    status="$(body_field '.status')"
    case "$status" in done | failed) break ;; esac
    if [ $(($(now_s) - start)) -ge "$timeout" ]; then
      if [ "$CITT_JSON" = 1 ]; then
        cat "$st"
        printf '\n'
      else
        jq -r '"Export \(.export_id) (\(.kind // "-")): \(.status)\(if .waiting_on then " on " + .waiting_on else "" end)"' "$st"
      fi
      err "$CITT_CMD: still running after $timeout s; re-run: $CITT_CMD $(project_ref) --apps $(shq "$apps") --export-id $export_id"
      exit 12
    fi
    poll_sleep "$(jq -r '.poll_after_seconds // empty' "$st")"
  done
  if [ "$status" = failed ]; then
    die 8 "export $export_id failed: $(jq -r '.error // "no error given"' "$st")"
  fi

  # Where the files go.
  local dir show gitignore=""
  if [ -n "$out" ]; then
    dir="$out"
  else
    if [ -z "$PROJECT_NAME" ]; then
      E_KIND=project
      call GET "$CITT_V1/projects"
      PROJECT_NAME="$(jq -r --argjson id "$PROJECT_ID" '.projects[] | select(.project_id == $id) | .name' "$RESP")"
      [ -n "$PROJECT_NAME" ] || PROJECT_NAME="project-$PROJECT_ID"
    fi
    local parent="${CITT_EXPORT_DIR:-./citt-exports}"
    dir="${parent%/}/$(slug "$PROJECT_NAME")"
    gitignore="${parent%/}/.gitignore"
  fi
  show="$dir"
  DL="$dir/.downloads"
  mkdir -p "$DL" 2>/dev/null || die 1 "cannot create $DL"
  chmod 700 "$DL"
  if [ -n "$gitignore" ] && [ ! -e "$gitignore" ]; then
    printf '# citt exports: per-app JSON, APKs and decompiled sources; keep them out of commits.\n*\n' >"$gitignore" \
      || die 1 "cannot write $gitignore"
  fi

  # Free space: the zip plus its extraction.
  local bytes need avail
  bytes="$(jq -r '.bytes // 0' "$st")"
  is_uint "$bytes" || bytes=0
  need=$((bytes * 2))
  avail="$(df -Pk "$DL" 2>/dev/null | awk 'NR == 2 { print $4 * 1024 }')"
  if is_uint "$avail" && [ "$avail" -lt "$need" ]; then
    die 1 "not enough free space in $dir: $avail bytes free, about $need needed"
  fi

  # Download, resuming a partial file, then check the zip hash.
  local zip part want got url
  zip="$DL/$export_id.zip"
  part="$zip.part"
  want="$(jq -r '.sha256 // empty' "$st")"
  url="$(jq -r '.download_url // empty' "$st")"
  [ -n "$url" ] || url="$CITT_V1/exports/$export_id/download"
  case "$url" in
    /*) ;;
    "$CITT_HOST"/*) url="${url#"$CITT_HOST"}" ;;
    *) die 1 "export $export_id has a download URL on another host: $url" ;;
  esac
  if [ ! -s "$zip" ] || [ "$(sha256_of "$zip")" != "$want" ]; then
    rm -f "$zip"
    HTTP_OUT="$part"
    HTTP_RESUME=1
    http GET "$url"
    if [ "$CODE" = 416 ]; then
      rm -f "$part"
      HTTP_OUT="$part"
      http GET "$url"
    fi
    case "$CODE" in
      200 | 206) ;;
      *)
        cp "$part" "$RESP" 2>/dev/null
        rm -f "$part"
        fail_http
        ;;
    esac
    mv -f "$part" "$zip"
  fi
  got="$(sha256_of "$zip")"
  if [ -n "$want" ] && [ "$got" != "$want" ]; then
    rm -f "$zip"
    die 11 "export $export_id failed verification: zip sha256 $got differs from $want"
  fi

  # Entry names, extraction, and the manifest hashes.
  local tmp man
  tmp="$DL/$export_id.tmp"
  rm -rf "$tmp"
  man="$(tmpfile manifest)"
  unzip -p "$zip" manifest.json >"$man" 2>/dev/null
  jq -e '.files | type == "array"' "$man" >/dev/null 2>&1 || die 11 "export $export_id rejected: no valid manifest.json"
  _check_entries "$export_id" "$zip" "$man"
  mkdir -p "$tmp/zip" "$tmp/stage"
  unzip -qq -o "$zip" -d "$tmp/zip" >/dev/null 2>&1 || { rm -rf "$tmp"; die 11 "export $export_id rejected: the zip cannot be extracted"; }
  local name sha
  while IFS=$'\t' read -r name sha; do
    got="$(sha256_of "$tmp/zip/$name" 2>/dev/null)"
    if [ "$got" != "$sha" ]; then
      rm -rf "$tmp"
      die 11 "export $export_id failed verification: $name sha256 ${got:-missing} differs from manifest $sha"
    fi
  done < <(jq -r '.files[] | [.name, .sha256] | @tsv' "$man")

  # Stage DESIGN-11's layout.
  local role platform pkg base
  base="$tmp/stage/$kind"
  mkdir -p "$base"
  cp "$tmp/zip/manifest.json" "$base/manifest.json"
  while IFS=$'\t' read -r name role platform pkg; do
    _unsafe_name "$platform/$pkg" && _reject "$export_id" "$name"
    case "$role" in
      app_json)
        if [ "$kind" = results ]; then
          mkdir -p "$base/$platform" && cp "$tmp/zip/$name" "$base/$platform/$pkg.json"
        else
          mkdir -p "$base/$platform/$pkg" && cp "$tmp/zip/$name" "$base/$platform/$pkg/app.json"
        fi
        ;;
      apk) mkdir -p "$base/$platform/$pkg" && cp "$tmp/zip/$name" "$base/$platform/$pkg/$pkg.apk" ;;
      tree)
        _check_tar "$export_id" "$tmp/zip/$name"
        mkdir -p "$base/$platform/$pkg/tree"
        if ! tar -xzf "$tmp/zip/$name" -C "$base/$platform/$pkg/tree" --no-same-owner; then
          rm -rf "$tmp"
          die 1 "cannot unpack the tree of $pkg"
        fi
        _defuse_tree "$base/$platform/$pkg/tree"
        ;;
    esac
  done < <(jq -r '.files[] | [.name, .role, .platform, .package_id] | @tsv' "$man")

  # The plugin document, before the stage is moved.
  local doc
  doc="$(tmpfile export_doc)"
  (cd "$tmp/stage" && find . -type f ! -path "./$kind/*/*/tree/*" ! -name manifest.json | sed 's|^\./||' | sort) | while IFS= read -r name; do
    platform="${name#"$kind"/}"
    platform="${platform%%/*}"
    pkg="${name#"$kind/$platform/"}"
    pkg="${pkg%%/*}"
    pkg="${pkg%.json}"
    jq -nc --arg p "$name" --arg pl "$platform" --arg pk "$pkg" --arg s "$(sha256_of "$tmp/stage/$name")" \
      --argjson b "$(file_bytes "$tmp/stage/$name")" '{path: $p, platform: $pl, package_id: $pk, sha256: $s, bytes: $b}'
  done | jq -s '.' >"$doc"

  : >"$_CITT_TMP/updated"
  _place "$tmp/stage" "$dir"
  rm -rf "$tmp"
  [ "$keep" = 1 ] || rm -f "$zip"

  local skipped
  skipped="$(jq -c '.skipped // empty' "$st")"
  [ -n "$skipped" ] && [ "$skipped" != null ] || skipped="$(jq -c '.missing // []' "$man")"
  if [ "$CITT_JSON" = 1 ]; then
    jq -c --argjson id "$export_id" --arg k "$kind" --arg d "$show" --argjson s "$skipped" \
      '{schema: "citt.plugin.export/1", export_id: $id, kind: $k, dir: $d, files: ., skipped: $s}' "$doc"
    return 0
  fi
  local requested
  requested="$(jq -r '.apps_requested // empty' "$st")"
  if [ "$kind" = results ]; then
    local files
    files="$(jq '[.files[] | select(.role == "app_json")] | length' "$man")"
    printf 'Export %s (results, %s app%s requested) done: %s file%s, %s bytes.\n' "$export_id" "${requested:-?}" \
      "$([ "${requested:-2}" = 1 ] || printf s)" "$files" "$([ "$files" = 1 ] || printf s)" "$bytes"
    printf 'Wrote %s/results/ (%s app JSON file%s, manifest.json).\n' "$show" "$files" "$([ "$files" = 1 ] || printf s)"
  else
    local napps
    napps="$(jq '[.files[].package_id] | unique | length' "$man")"
    printf 'Export %s (sources, %s app%s) done: %s app%s, %s bytes.\n' "$export_id" "${requested:-$napps}" \
      "$([ "${requested:-$napps}" = 1 ] || printf s)" "$napps" "$([ "$napps" = 1 ] || printf s)" "$bytes"
    while IFS=$'\t' read -r platform pkg; do
      local d="$show/sources/$platform/$pkg" parts="" tf
      [ -f "$d/app.json" ] && parts="app.json"
      [ -f "$d/$pkg.apk" ] && parts="$parts${parts:+, }$pkg.apk"
      if [ -d "$d/tree" ]; then
        tf="$(find "$d/tree" -type f | wc -l | tr -d ' ')"
        parts="$parts${parts:+, }tree/ with $tf file$([ "$tf" = 1 ] || printf s)"
      fi
      printf 'Wrote %s/ (%s).\n' "$d" "$parts"
    done < <(jq -r '[.files[] | [.platform, .package_id]] | unique[] | @tsv' "$man")
  fi
  if [ -s "$_CITT_TMP/renamed" ]; then
    printf 'Renamed %s agent instruction files or folders so an agent does not load them (each now ends .txt): %s\n' \
      "$(wc -l <"$_CITT_TMP/renamed" | tr -d ' ')" "$(paste -sd, "$_CITT_TMP/renamed" | sed 's/,/, /g')"
  fi
  if [ "$UPDATED" -gt 0 ]; then
    printf '%s file%s updated since the last export.\n' "$UPDATED" "$([ "$UPDATED" = 1 ] || printf s)"
  fi
  if [ "$(jq 'length' <<<"$skipped")" -gt 0 ]; then
    jq -r 'length as $n | "Skipped \($n) app\(if $n == 1 then "" else "s" end) without a scan: "
      + (group_by(.reason) | map("\(.[0].reason) \(length)") | join(", ")) + " (listed in manifest.json)."' <<<"$skipped"
  fi
}
