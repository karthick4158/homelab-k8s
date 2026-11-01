#!/usr/bin/env bash
# Show the public IP every container of the media/downloads pod is seen as by
# the internet, next to this machine's (home) public IP, to prove all of the
# pod's traffic leaves through the gluetun VPN. Read-only: it only runs
# `kubectl get` and `kubectl exec ... curl/wget`, it never changes the cluster.
#
# All containers in the pod share one network namespace, so they should all
# show the same VPN IP; each one is still queried on its own.
#
# Gluetun also has an HTTP control server that can report the public IP, but
# this repo does not configure it (components/gluetun sets no
# HTTP_CONTROL_SERVER_* settings), so this script does not use it.
#
# Needs: bash 3.2+ (macOS default), curl, ssh (unless SSH_TARGET=""), and
# kubectl on the ssh target (or locally).
# Usage: scripts/vpn-check.sh
#   SSH_TARGET  where kubectl runs (default k8s@10.0.0.88; "" = run locally)
#   IP_URL      plain-text "what is my IP" service (default
#               https://api.ipify.org, IPv4 only so home and VPN compare
#               like for like)
# Exit: 0 OK, 1 LEAK (a container shows the home IP), 2 WARN (lookups
# disagree, failed, or the home IP is unknown), 3 pod not found.

set -u

SSH_TARGET=${SSH_TARGET-k8s@10.0.0.88}
IP_URL=${IP_URL:-https://api.ipify.org}
NAMESPACE=media
# Pod template label of the downloads Deployment (apps/media/downloads.yaml).
SELECTOR=app=downloads

kube() {
  if [ -n "$SSH_TARGET" ]; then
    # One quoted string so the remote shell keeps each argument intact.
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_TARGET" "kubectl $(printf '%q ' "$@")"
  else
    kubectl "$@"
  fi
}

# Keep only something that looks like an IPv4/IPv6 address, else nothing.
ip_only() {
  tr -d ' \r\n' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9a-fA-F:]+:[0-9a-fA-F:]*$'
}

# Run inside a container: curl, then wget, else say neither exists. One line
# (no newlines) so printf %q in kube() stays plain POSIX-sh quoting.
in_pod_lookup() {
  printf '%s' "u='$IP_URL'; out=''; " \
    "if command -v curl >/dev/null 2>&1; then out=\$(curl -fsS --max-time 8 \"\$u\" 2>/dev/null); fi; " \
    "if [ -z \"\$out\" ] && command -v wget >/dev/null 2>&1; then out=\$(wget -qO- -T 8 \"\$u\" 2>/dev/null); fi; " \
    "if [ -n \"\$out\" ]; then echo \"\$out\"; " \
    "elif command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then echo LOOKUP-FAILED; " \
    "else echo NO-TOOL; fi"
}

# verdict HOME_IP [CONTAINER_IP ...]
# Pure function (no I/O besides stdout). An empty CONTAINER_IP means that
# container's lookup failed. Prints "OK|LEAK|WARN: reason" and returns 0/1/2.
verdict() {
  home=$1; shift
  first="" ok=0 differ=0 leak=0
  for ip in "$@"; do
    [ -n "$ip" ] || continue
    ok=$((ok + 1))
    [ -n "$home" ] && [ "$ip" = "$home" ] && leak=1
    if [ -z "$first" ]; then first=$ip; elif [ "$ip" != "$first" ]; then differ=1; fi
  done
  if [ "$leak" -eq 1 ]; then
    echo "LEAK: a container is seen as the home IP $home"; return 1
  fi
  if [ "$ok" -eq 0 ]; then
    echo "WARN: no container lookup succeeded"; return 2
  fi
  if [ "$differ" -eq 1 ]; then
    echo "WARN: containers are seen as different IPs"; return 2
  fi
  if [ -z "$home" ]; then
    echo "WARN: home IP unknown, cannot compare (all containers show $first)"; return 2
  fi
  echo "OK: all $ok lookups show $first, not the home IP $home"; return 0
}

main() {
  case ${1-} in
    -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; return 0 ;;
  esac

  if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    red=$(tput setaf 1) green=$(tput setaf 2) yellow=$(tput setaf 3) reset=$(tput sgr0)
  else
    red="" green="" yellow="" reset=""
  fi

  pod=$(kube -n "$NAMESPACE" get pod -l "$SELECTOR" --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$pod" ]; then
    echo "No running pod with label $SELECTOR in namespace $NAMESPACE." >&2
    return 3
  fi

  # Sidecar init containers (restartPolicy Always, e.g. gluetun) keep running
  # and are queried; one-shot init containers (transmission-seed) have exited
  # and are skipped. Then all regular containers.
  containers=$(kube -n "$NAMESPACE" get pod "$pod" -o jsonpath='{range .spec.initContainers[*]}{.name} {.restartPolicy}{"\n"}{end}{range .spec.containers[*]}{.name} main{"\n"}{end}' \
    | awk '$2 == "Always" || $2 == "main" { print $1 }')

  home=$(curl -fsS --max-time 8 "$IP_URL" 2>/dev/null | ip_only)

  echo "Pod: $NAMESPACE/$pod   (IP service: $IP_URL)"
  printf '%-24s %s\n' CONTAINER "PUBLIC IP"
  set --
  for c in $containers; do
    raw=$(kube -n "$NAMESPACE" exec "$pod" -c "$c" -- sh -c "$(in_pod_lookup)" 2>/dev/null)
    ip=$(printf '%s' "$raw" | ip_only)
    case $raw in
      *NO-TOOL*) shown="n/a (no curl/wget in this container)" ;;
      *LOOKUP-FAILED*) shown="lookup failed" ;;
      *) if [ -n "$ip" ]; then shown=$ip; elif [ -z "$raw" ]; then shown="n/a (exec failed or no sh)"; else shown="unexpected reply"; fi ;;
    esac
    printf '%-24s %s\n' "$c" "$shown"
    set -- "$@" "$ip"
  done
  printf '%-24s %s\n' "Home IP (this machine)" "${home:-lookup failed}"
  echo

  line=$(verdict "$home" "$@"); rc=$?
  case $rc in
    0) echo "${green}${line}${reset}" ;;
    1) echo "${red}${line}${reset}" ;;
    *) echo "${yellow}${line}${reset}" ;;
  esac
  return "$rc"
}

# Run only when executed, so tests can source this file and call verdict.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit $?
fi
