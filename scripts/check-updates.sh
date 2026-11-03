#!/usr/bin/env bash
# Find newer versions of everything pinned in this repo and, if asked, apply
# them: container image tags (`image:` lines under apps/, components/,
# infrastructure/) and Helm chart versions (`targetRevision:` in
# argocd-apps/*.yaml Applications that have `chart:` + an https `repoURL`).
# It only asks public registries / Helm repo indexes, never the cluster.
#
# Usage:
#   scripts/check-updates.sh             pick updates, edit files, commit, push
#   scripts/check-updates.sh --dry-run   list only; never edits, commits or pushes
#   scripts/check-updates.sh -h|--help   show this help
#
# Flow: numbered table of outdated items ("!! major" = major version jump,
# "careful" = app that has broken on upgrades before) -> pick numbers
# (a = all non-major, q = quit) -> files edited in place -> full git diff ->
# "Commit? [y/N]" (one commit per app containing only that app's edited
# lines) -> "Push now? [y/N]". Argo CD applies what is pushed to main.
#
# Skipped (listed with the reason): tags `latest`, digest-pinned images,
# private registries (PRIVATE_PREFIXES), unsupported registries, and lines in
# files that already had uncommitted changes when the script started.
#
# Needs: bash 3.2+ (macOS default), curl, git, grep, sed, sort, awk, tr.
#   PRIVATE_PREFIXES  space-separated image prefixes that need credentials
#                     (default "ghcr.io/karthick4158/")

set -u

PRIVATE_PREFIXES=${PRIVATE_PREFIXES:-ghcr.io/karthick4158/}
CAREFUL_APPS="gluetun plex argo-cd argocd traefik traefik-crds kube-prometheus-stack"
LOOKUP_SLEEP=0.3

DRY_RUN=0
TMPD=""
DIRTY_FILES=""

# Outdated items, as parallel arrays (bash 3.2 has no associative arrays).
N=0
IT_APP=() IT_NAME=() IT_CUR=() IT_NEW=() IT_FILE=() IT_LINE=() IT_OLD=() IT_REPL=() IT_MAJOR=()
SKIPPED=""
UNRESOLVED=""
UPTODATE=0

usage() { sed -n '2,/^$/{s/^# \{0,1\}//;p;}' "$0"; }

fetch() { curl -fsS --connect-timeout 5 --max-time 60 "$@"; }

# Print only the tags (one per line on stdin) that have the same shape as
# the pinned tag $1. The shape is the pinned tag with every run of digits
# replaced by "any number" and every "-"-separated git hash (7+ hex chars
# with a letter, e.g. plex's "e5521bd8c") replaced by "any hex". So:
#   6.4.4.10685-ls321  only matches  N.N.N.N-lsN
#   v3.5.1             only matches  vN.N.N   (not v3.6.0-rc1)
# This drops latest/develop/nightly, pre-releases and arch-prefixed tags
# (amd64-...) without a per-image list of exceptions.
same_shape() {
  awk -v pinned="$1" '
    function shape(t,   n, parts, i, p, out, j, c, indigit, re) {
      n = split(t, parts, "-")
      re = ""
      for (i = 1; i <= n; i++) {
        p = parts[i]
        if (length(p) >= 7 && p ~ /^[0-9a-f]+$/ && p ~ /[a-f]/) {
          out = "[0-9a-f]+"
        } else {
          out = ""; indigit = 0
          for (j = 1; j <= length(p); j++) {
            c = substr(p, j, 1)
            if (c ~ /[0-9]/) {
              if (!indigit) out = out "[0-9]+"
              indigit = 1
              continue
            }
            indigit = 0
            if (c ~ /[A-Za-z_]/) out = out c
            else out = out "\\" c
          }
        }
        re = re (i > 1 ? "-" : "") out
      }
      return "^" re "$"
    }
    BEGIN { re = shape(pinned) }
    $0 ~ re { print }
  '
}

# Newest of the same-shape tags on stdin, or nothing.
newest_like() {
  same_shape "$1" | sort -V | tail -n 1
}

# True if $2 sorts after $1.
is_newer() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$2" ]
}

# True if $1 -> $2 is a major jump: the first number differs, or both start
# with 0 and the second number differs (0.x minors break by convention).
is_major() {
  local a b
  a=$(printf '%s\n' "$1" | awk '{ if (match($0, /[0-9]+/)) { split(substr($0, RSTART), p, /[^0-9]+/); print p[1] + 0, p[2] + 0 } }')
  b=$(printf '%s\n' "$2" | awk '{ if (match($0, /[0-9]+/)) { split(substr($0, RSTART), p, /[^0-9]+/); print p[1] + 0, p[2] + 0 } }')
  [ "${a% *}" != "${b% *}" ] && return 0
  [ "${a% *}" = 0 ] && [ "$a" != "$b" ]
}

is_careful() {
  case " $CAREFUL_APPS " in *" $1 "*) return 0 ;; esac
  return 1
}

# Anonymous pull token from token URL $1.
get_token() {
  fetch "$1" 2>/dev/null | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

# All tags of repo $2 on registry API host $1 (Docker registry v2 API),
# one per line, following the Link: rel="next" pagination. Token in $3.
list_tags() {
  local host=$1 repo=$2 token=$3 url resp next pages=0
  url="https://$host/v2/$repo/tags/list?n=1000"
  while [ -n "$url" ] && [ "$pages" -lt 50 ]; do
    resp=$(fetch -i -H "Authorization: Bearer $token" "$url" 2>/dev/null) || return 1
    resp=$(printf '%s\n' "$resp" | tr -d '\r')
    printf '%s\n' "$resp" | awk 'body { print } /^$/ { body = 1 }' \
      | sed -n 's/.*"tags"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' \
      | tr ',' '\n' | tr -d '" '
    next=$(printf '%s\n' "$resp" | awk '/^$/ { exit } { print }' \
      | grep -i '^link:' | sed -n 's/.*<\([^>]*\)>.*rel="next".*/\1/p')
    case $next in
      /*) url="https://$host$next" ;;
      *) url=$next ;;
    esac
    pages=$((pages + 1))
  done
}

# Registry and repo of image name $1 (no tag), as "registry repo".
split_image() {
  local name=$1 first rest
  first=${name%%/*}
  rest=${name#*/}
  case $first in
    *.*|*:*|localhost) ;;
    *) first=docker.io; rest=$name ;;
  esac
  [ "$first" = "$name" ] && { first=docker.io; rest=$name; }
  echo "$first $rest"
}

# Newest same-shape tag for image $1 (no tag) pinned at $2, or "?". Tag lists
# are cached per repo in $TMPD so an image used twice is fetched once.
newest_image_tag() {
  local name=$1 tag=$2 reg repo host token cache tags
  set -- $(split_image "$name")
  reg=$1 repo=$2
  case $reg in
    ghcr.io|lscr.io)
      # lscr.io/linuxserver/x is served from ghcr.io/linuxserver/x.
      host=ghcr.io ;;
    docker.io|index.docker.io|registry-1.docker.io)
      host=registry-1.docker.io
      case $repo in */*) ;; *) repo="library/$repo" ;; esac ;;
    *)
      echo "?"; return ;;
  esac
  cache="$TMPD/tags_$(printf '%s' "$host/$repo" | tr -c 'A-Za-z0-9' '_')"
  if [ ! -f "$cache" ]; then
    if [ "$host" = ghcr.io ]; then
      token=$(get_token "https://ghcr.io/token?scope=repository:$repo:pull")
    else
      token=$(get_token "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$repo:pull")
    fi
    sleep "$LOOKUP_SLEEP"
    [ -n "$token" ] || { echo "?"; return; }
    list_tags "$host" "$repo" "$token" > "$cache.part" || { rm -f "$cache.part"; echo "?"; return; }
    mv "$cache.part" "$cache"
  fi
  tags=$(newest_like "$tag" < "$cache")
  echo "${tags:-?}"
}

# Chart versions of chart $2 in Helm repo $1 (from its index.yaml), one per
# line. Indexes are cached per repo URL in $TMPD.
chart_versions() {
  local repo=${1%/} chart=$2 cache
  cache="$TMPD/index_$(printf '%s' "$repo" | tr -c 'A-Za-z0-9' '_')"
  if [ ! -f "$cache" ]; then
    fetch "$repo/index.yaml" > "$cache.part" 2>/dev/null || { rm -f "$cache.part"; return 1; }
    mv "$cache.part" "$cache"
    sleep "$LOOKUP_SLEEP"
  fi
  # Chart versions are the entry-level "version:" keys under entries.<chart>
  # (deeper ones belong to dependencies).
  awk -v chart="$chart" '
    /^entries:/ { inentries = 1; next }
    inentries && /^[^ ]/ { inentries = 0 }
    !inentries { next }
    /^  [^ -][^:]*:[[:space:]]*$/ {
      name = $1; sub(/:$/, "", name); gsub(/["\047]/, "", name)
      cur = (name == chart); item = -1; next
    }
    !cur { next }
    /^[[:space:]]*- / {
      ind = match($0, /-/) - 1
      if (item < 0) item = ind
      if (ind == item && $2 == "version:") print $3
      next
    }
    item >= 0 && $1 == "version:" && match($0, /[^ ]/) - 1 == item + 2 { print $2 }
  ' "$cache" | tr -d "\"'"
}

skip() { SKIPPED="$SKIPPED$(printf '  %-44s %s' "$1" "$2")
"; }
unresolved() { UNRESOLVED="$UNRESOLVED$(printf '  %-44s %s' "$1" "$2")
"; }

is_dirty() {
  case "
$DIRTY_FILES
" in *"
$1
"*) return 0 ;; esac
  return 1
}

# Record an outdated item: app name cur new file line old-string new-string.
add_item() {
  IT_APP[N]=$1 IT_NAME[N]=$2 IT_CUR[N]=$3 IT_NEW[N]=$4 IT_FILE[N]=$5 IT_LINE[N]=$6
  IT_OLD[N]=$7 IT_REPL[N]=$8
  if is_major "$3" "$4"; then IT_MAJOR[N]=1; else IT_MAJOR[N]=0; fi
  N=$((N + 1))
}

scan_images() {
  local dirs="" d line file rest lineno ref name tag newest p
  for d in apps components infrastructure; do [ -d "$d" ] && dirs="$dirs $d"; done
  [ -n "$dirs" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    file=${line%%:*}
    rest=${line#*:}
    lineno=${rest%%:*}
    ref=$(printf '%s\n' "${rest#*:}" | sed -e 's/^.*image:[[:space:]]*//' \
      -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' -e "s/[\"']//g")
    case $ref in
      *@*) skip "${ref%%@*}" "digest-pinned  ($file:$lineno)"; continue ;;
    esac
    case ${ref##*/} in
      *:*) tag=${ref##*:}; name=${ref%:*} ;;
      *) skip "$ref" "no tag pinned  ($file:$lineno)"; continue ;;
    esac
    if [ "$tag" = latest ]; then
      skip "$name" "tag 'latest' (pin a version to track it)  ($file:$lineno)"; continue
    fi
    for p in $PRIVATE_PREFIXES; do
      case $ref in "$p"*) skip "$name" "private registry, needs credentials  ($file:$lineno)"; continue 2 ;; esac
    done
    case $(split_image "$name") in
      "ghcr.io "*|"lscr.io "*|"docker.io "*|"index.docker.io "*|"registry-1.docker.io "*) ;;
      *) skip "$name" "registry not supported  ($file:$lineno)"; continue ;;
    esac
    if [ "$DRY_RUN" = 0 ] && is_dirty "$file"; then
      skip "$name" "file has uncommitted changes  ($file:$lineno)"; continue
    fi
    newest=$(newest_image_tag "$name" "$tag")
    if [ "$newest" = "?" ]; then
      unresolved "$name:$tag" "registry lookup failed  ($file:$lineno)"
    elif is_newer "$tag" "$newest"; then
      add_item "${name##*/}" "$name" "$tag" "$newest" "$file" "$lineno" "$name:$tag" "$name:$newest"
    else
      UPTODATE=$((UPTODATE + 1))
    fi
  done <<EOF
$(grep -rn -E '^[[:space:]]*(-[[:space:]]*)?image:' $dirs \
    --include='*.yaml' --include='*.yml' --exclude='*.sops.yaml' --exclude='*.sops.yml' 2>/dev/null \
    | grep -v -E '\.sops\.ya?ml:')
EOF
}

scan_charts() {
  local f repo chart pinned lineno newest
  for f in argocd-apps/*.yaml argocd-apps/*.yml; do
    [ -f "$f" ] || continue
    case $f in *.sops.yaml|*.sops.yml) continue ;; esac
    # shellcheck disable=SC2046 # word-split "repo chart version line" on purpose
    set -- $(awk '
      /^[[:space:]]*repoURL:/        { r = $2 }
      /^[[:space:]]*chart:/          { c = $2 }
      /^[[:space:]]*targetRevision:/ { v = $2; l = NR }
      END { if (c != "") { gsub(/["\047]/, "", r); gsub(/["\047]/, "", c); gsub(/["\047]/, "", v); print r, c, v, l } }
    ' "$f")
    [ $# -eq 4 ] || continue
    repo=$1 chart=$2 pinned=$3 lineno=$4
    case $repo in
      https://*|http://*) ;;
      *) unresolved "$chart:$pinned" "OCI/non-https chart repo $repo  ($f)"; continue ;;
    esac
    if [ "$DRY_RUN" = 0 ] && is_dirty "$f"; then
      skip "$chart" "file has uncommitted changes  ($f:$lineno)"; continue
    fi
    newest=$(chart_versions "$repo" "$chart" | newest_like "$pinned")
    if [ -z "$newest" ]; then
      unresolved "$chart:$pinned" "not found in $repo/index.yaml  ($f)"
    elif is_newer "$pinned" "$newest"; then
      add_item "$chart" "$chart (chart)" "$pinned" "$newest" "$f" "$lineno" "$pinned" "$newest"
    else
      UPTODATE=$((UPTODATE + 1))
    fi
  done
}

print_table() {
  local i marks
  printf '%3s  %-38s %-30s    %-30s %s\n' "#" NAME CURRENT LATEST FILE
  i=0
  while [ "$i" -lt "$N" ]; do
    marks=""
    [ "${IT_MAJOR[i]}" = 1 ] && marks="$marks  !! major"
    is_careful "${IT_APP[i]}" && marks="$marks  careful"
    printf '%3s  %-38s %-30s -> %-30s (%s)%s\n' "$((i + 1))" "${IT_NAME[i]}" "${IT_CUR[i]}" \
      "${IT_NEW[i]}" "${IT_FILE[i]}:${IT_LINE[i]}" "$marks"
    i=$((i + 1))
  done
}

print_report() {
  echo
  if [ "$N" -eq 0 ]; then
    echo "Everything that could be checked is up to date ($UPTODATE items)."
  else
    echo "== Outdated ($N; $UPTODATE up to date) =="
    print_table
  fi
  if [ -n "$UNRESOLVED" ]; then
    echo
    echo "== Could not resolve =="
    printf '%s' "$UNRESOLVED"
  fi
  if [ -n "$SKIPPED" ]; then
    echo
    echo "== Skipped =="
    printf '%s' "$SKIPPED"
  fi
}

# Replace the first literal $3 with $4 on line $2 of file $1, in place.
# Fails and leaves the file alone if that line does not contain $3.
replace_on_line() {
  local file=$1 lineno=$2 old=$3 new=$4 tmp="$TMPD/edit"
  awk -v ln="$lineno" -v old="$old" -v new="$new" '
    NR == ln {
      i = index($0, old)
      if (i == 0) bad = 1
      else $0 = substr($0, 1, i - 1) new substr($0, i + length(old))
    }
    { print }
    END { exit bad }
  ' "$file" > "$tmp" || return 1
  cat "$tmp" > "$file"
}

# y/N prompt; true only for y/yes.
confirm() {
  local ans
  printf '%s [y/N] ' "$1"
  read -r ans || { echo; return 1; }
  case $ans in y|Y|yes|YES|Yes) return 0 ;; esac
  return 1
}

# Ask which items to apply; sets SEL to space-separated 0-based indexes.
choose() {
  local ans t i ok
  while :; do
    printf 'Select updates to apply (numbers like 1 3 5, a=all non-major, q=quit): '
    read -r ans || { echo; echo "No input; nothing changed."; exit 0; }
    SEL="" ok=1
    case $ans in
      q|Q) echo "Nothing changed."; exit 0 ;;
      a|A)
        i=0
        while [ "$i" -lt "$N" ]; do
          [ "${IT_MAJOR[i]}" = 0 ] && SEL="$SEL $i"
          i=$((i + 1))
        done
        [ -n "$SEL" ] || { echo "Every item is a major update; pick them by number."; continue; }
        ;;
      *)
        for t in $ans; do
          case $t in
            *[!0-9]*) ok=0 ;;
            *) if [ "$t" -lt 1 ] || [ "$t" -gt "$N" ]; then ok=0; fi ;;
          esac
          [ "$ok" = 1 ] || { echo "Invalid choice '$t': use numbers 1-$N, 'a' or 'q'."; break; }
          case " $SEL " in *" $((t - 1)) "*) ;; *) SEL="$SEL $((t - 1))" ;; esac
        done
        [ "$ok" = 1 ] || continue
        [ -n "$SEL" ] || { echo "Nothing selected."; continue; }
        ;;
    esac
    return 0
  done
}

# Edit the working tree for every selected item; sets DONE (indexes that
# applied) and EDITED (changed files, newline-separated).
apply_selected() {
  local i
  DONE="" EDITED=""
  for i in $SEL; do
    echo
    echo "-> ${IT_NAME[i]}: ${IT_CUR[i]} -> ${IT_NEW[i]}  (${IT_FILE[i]}:${IT_LINE[i]})"
    if replace_on_line "${IT_FILE[i]}" "${IT_LINE[i]}" "${IT_OLD[i]}" "${IT_REPL[i]}"; then
      DONE="$DONE $i"
      case "
$EDITED
" in *"
${IT_FILE[i]}
"*) ;; *) EDITED="$EDITED${EDITED:+
}${IT_FILE[i]}" ;; esac
      git --no-pager diff --stat -- "${IT_FILE[i]}"
    else
      echo "   !! '${IT_OLD[i]}' not found on that line; left unchanged."
    fi
  done
}

# One commit per app. Each commit is built in the index from the index copy
# of each file plus only that app's line edits, so two apps edited in the
# same file (e.g. apps/media/downloads.yaml) still get separate commits and
# nothing else from the working tree is committed.
commit_per_app() {
  local apps="" app i f files olds news mode blob stage="$TMPD/stage" count=0
  for i in $DONE; do
    case " $apps " in *" ${IT_APP[i]} "*) ;; *) apps="$apps ${IT_APP[i]}" ;; esac
  done
  for app in $apps; do
    files="" olds="" news=""
    for i in $DONE; do
      [ "${IT_APP[i]}" = "$app" ] || continue
      case " $files " in *" ${IT_FILE[i]} "*) ;; *) files="$files ${IT_FILE[i]}" ;; esac
      case ", $olds, " in *", ${IT_CUR[i]}, "*) ;; *) olds="$olds${olds:+, }${IT_CUR[i]}" ;; esac
      case ", $news, " in *", ${IT_NEW[i]}, "*) ;; *) news="$news${news:+, }${IT_NEW[i]}" ;; esac
    done
    for f in $files; do
      git show ":$f" > "$stage" || return 1
      for i in $DONE; do
        [ "${IT_APP[i]}" = "$app" ] && [ "${IT_FILE[i]}" = "$f" ] || continue
        replace_on_line "$stage" "${IT_LINE[i]}" "${IT_OLD[i]}" "${IT_REPL[i]}" \
          || { echo "!! could not stage $app in $f; stopping."; return 1; }
      done
      mode=$(git ls-files -s -- "$f" | awk '{ print $1; exit }')
      blob=$(git hash-object -w -- "$stage") || return 1
      git update-index --cacheinfo "${mode:-100644}" "$blob" "$f" || return 1
    done
    git commit -q -m "$app: update $olds -> $news" || return 1
    count=$((count + 1))
  done
  echo
  git --no-pager log --oneline -n "$count"
}

on_interrupt() {
  echo
  echo "Interrupted. Files already edited stay edited; see 'git status' / 'git diff'."
  exit 130
}

cleanup() { [ -n "$TMPD" ] && rm -rf "$TMPD"; }

main() {
  case ${1:-} in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac

  cd "${REPO_ROOT:-$(dirname "$0")/..}" || exit 1
  TMPD=$(mktemp -d "${TMPDIR:-/tmp}/check-updates.XXXXXX") || exit 1
  trap cleanup EXIT
  trap on_interrupt INT TERM

  if [ "$DRY_RUN" = 0 ]; then
    DIRTY_FILES=$(git status --porcelain | sed 's/^...//; s/.* -> //')
    if [ -n "$DIRTY_FILES" ]; then
      echo "The working tree has uncommitted changes:"
      git status --short
      echo "This script only stages and commits the lines it edits, and skips files listed above."
      confirm "Continue anyway?" || exit 1
    fi
  fi

  echo "Checking container images and Helm charts (public registries only)..."
  scan_images
  scan_charts
  print_report

  if [ "$DRY_RUN" = 1 ]; then
    echo
    echo "Dry run: nothing edited."
    exit 0
  fi
  [ "$N" -gt 0 ] || exit 0

  echo
  echo "Read the release notes first, especially for '!! major' and 'careful' items."
  choose
  apply_selected
  [ -n "$DONE" ] || { echo "Nothing was changed."; exit 1; }

  echo
  echo "== Full diff =="
  # shellcheck disable=SC2086 # EDITED holds repo paths without spaces
  git --no-pager diff -- $EDITED

  echo
  if ! confirm "Commit?"; then
    echo "Not committed. Edits are in the working tree; undo with: git checkout -- $(echo $EDITED)"
    exit 0
  fi
  if ! git diff --cached --quiet; then
    echo "Something else is already staged ('git diff --cached'); not committing so it is not mixed in."
    echo "Edits are in the working tree."
    exit 1
  fi
  commit_per_app || { echo "Commit failed; check 'git status'."; exit 1; }

  echo
  if confirm "Push now?"; then
    git push
  else
    echo "Not pushed. Argo CD only applies the update after: git push"
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
