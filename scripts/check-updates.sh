#!/usr/bin/env bash
# Show, for every container image and Helm chart pinned in this repo, the
# version in use and the newest one available upstream. Read-only: it never
# writes files and never talks to the cluster, only to public registries.
#
# Needs: bash 3.2+ (macOS default), curl, grep, sed, sort, awk, tr.
# Usage: scripts/check-updates.sh

set -u

cd "$(dirname "$0")/.." || exit 1

fetch() { curl -fsS --connect-timeout 5 --max-time 60 "$@"; }
row() { printf '%-34s %-30s %-30s %s\n' "$@"; }

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

# "up to date" / "update available" for pinned $1 vs newest $2.
status_of() {
  if [ "$1" = "$2" ]; then
    echo "up to date"
  elif [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$2" ]; then
    echo "update available"
  else
    echo "up to date (pinned is newer)"
  fi
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

# Newest same-shape tag for image reference $1 (registry/repo:tag), or "?".
newest_image_tag() {
  local ref=$1 name tag first rest host repo token tags
  name=${ref%%@*}
  tag=${name##*:}
  name=${name%:*}
  first=${name%%/*}
  rest=${name#*/}
  case $first in
    *.*|*:*|localhost) ;;
    *) first=docker.io; rest=$name ;;
  esac
  [ "$first" = "$name" ] && { first=docker.io; rest=$name; }
  case $first in
    ghcr.io|lscr.io)
      # lscr.io/linuxserver/x is served from ghcr.io/linuxserver/x.
      host=ghcr.io; repo=$rest
      token=$(get_token "https://ghcr.io/token?scope=repository:$repo:pull")
      ;;
    docker.io|index.docker.io|registry-1.docker.io)
      host=registry-1.docker.io; repo=$rest
      case $repo in */*) ;; *) repo="library/$repo" ;; esac
      token=$(get_token "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$repo:pull")
      ;;
    *)
      echo "?"; return ;;
  esac
  [ -n "$token" ] || { echo "?"; return; }
  tags=$(list_tags "$host" "$repo" "$token") || { echo "?"; return; }
  tags=$(printf '%s\n' "$tags" | newest_like "$tag")
  echo "${tags:-?}"
}


echo "== Container images (apps/, components/) =="
row IMAGE PINNED NEWEST STATUS
grep -rn -E '^[[:space:]]*(-[[:space:]]*)?image:' apps components 2>/dev/null \
  | grep -E '\.ya?ml:' | grep -v -E '\.sops\.ya?ml:' \
  | while IFS= read -r line; do
      ref=$(printf '%s\n' "$line" | sed -e 's/^[^:]*:[0-9]*:[^:]*image:[[:space:]]*//' \
        -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' -e "s/[\"']//g")
      file=${line%%:*}
      name=${ref%%@*}
      case ${name##*/} in
        *:*) tag=${name##*:}; name=${name%:*} ;;
        *) row "$name" "(none)" "?" "no tag pinned  [$file]"; continue ;;
      esac
      newest=$(newest_image_tag "$ref")
      if [ "$newest" = "?" ]; then
        status="lookup failed"
      else
        status=$(status_of "$tag" "$newest")
      fi
      row "$name" "$tag" "$newest" "$status  [$file]"
    done

echo
echo "== Helm charts (argocd-apps/) =="
row CHART PINNED NEWEST STATUS
for f in argocd-apps/*.yaml; do
  # shellcheck disable=SC2046 # word-split "repo chart version" on purpose
  set -- $(awk '
    /^[[:space:]]*repoURL:/        { r = $2 }
    /^[[:space:]]*chart:/          { c = $2 }
    /^[[:space:]]*targetRevision:/ { v = $2 }
    END { if (c != "") { gsub(/["\047]/, "", r); gsub(/["\047]/, "", c); gsub(/["\047]/, "", v); print r, c, v } }
  ' "$f")
  [ $# -eq 3 ] || continue
  repo=$1 chart=$2 pinned=$3
  case $repo in
    https://*|http://*)
      # Chart versions are the entry-level "version:" keys under entries.<chart>
      # in index.yaml (deeper ones belong to dependencies).
      newest=$(fetch "${repo%/}/index.yaml" 2>/dev/null | awk -v chart="$chart" '
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
      ' | tr -d "\"'" | newest_like "$pinned")
      if [ -z "$newest" ]; then
        row "$chart" "$pinned" "?" "lookup failed  [$repo]"
      else
        row "$chart" "$pinned" "$newest" "$(status_of "$pinned" "$newest")  [$repo]"
      fi
      ;;
    *)
      row "$chart" "$pinned" "?" "skipped: OCI/non-https repo  [$repo]"
      ;;
  esac
done

echo
echo "Read the release notes before bumping; update one app per commit."
