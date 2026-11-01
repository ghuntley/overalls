#!/usr/bin/env bash
# Runs one Mix action inside a bubblewrap sandbox that mirrors the Nix build
# sandbox (ADR-0269; contract mix-actions-sandboxed in buck/CONTRACTS).
#
# usage: mix_sandbox.sh BWRAP STATE PHASES SCRIPT TREE ARG...
#   STATE   mixRelease shell state from the [mix] cells section
#   PHASES  buck/mix_phases.sh, sourced after STATE
#   SCRIPT  the action's generated variables and entry call
#   TREE    manifest of "relative-path<TAB>artifact" lines; each artifact
#           is copied to /build-src/source/<relative-path>
#   ARG     each existing path is bound read-only at /arg/N; any other
#           argument is an output, written by the action to /io/N and moved
#           to that path afterwards. "-" is a placeholder.
set -euo pipefail
bwrap=$1 state=$2 phases=$3 script=$4 tree=$5
shift 5
root=$(pwd)
scratch="$root/${BUCK_SCRATCH_PATH:?mix_sandbox.sh runs as a Buck2 action}"
# Removed on exit: the sandbox user owns everything here, but read-only
# copies of store trees need write permission before they can be deleted.
cleanup() { chmod -R u+w "$scratch" 2>/dev/null || true; rm -rf "$scratch"; }
trap cleanup EXIT
cleanup
mkdir -p "$scratch/build" "$scratch/src" "$scratch/io" "$scratch/etc" "$scratch/in"
mkdir -p "$scratch/src/source"
# Source files already sit at their repository path; copy those in bulk.
# Package directories (owned sets) are copied to their package path.
while IFS=$'\t' read -r rel artifact || [[ -n ${rel-} ]]; do
  if [[ $rel == @* ]]; then
    continue
  elif [[ $rel == "$artifact" ]]; then
    printf '%s\0' "$artifact"
  else
    mkdir -p "$scratch/src/source/$rel"
    cp -RL "$artifact/." "$scratch/src/source/$rel/"
  fi
done < "$tree" | xargs -0 -r cp -L --parents -t "$scratch/src/source"
chmod -R u+w "$scratch/src/source"
# Directives after the files: store overlays copied over the root, then the
# mode reset that `cp --no-preserve=mode` applies to the Nix source.
while IFS=$'\t' read -r rel artifact || [[ -n ${rel-} ]]; do
  case $rel in
    @overlay) cp -r --no-preserve=mode "$artifact/." "$scratch/src/source/" ;;
    @reset-modes) find "$scratch/src/source" -type f -exec chmod 0644 {} + ;;
  esac
done < "$tree"
chmod -R u+w "$scratch/src/source"
# Store sources have mtime 1. Mix, phx.digest and stdenv's SOURCE_DATE_EPOCH
# hook read mtimes, so the copy matches the store.
find "$scratch/src/source" -exec touch -h -d @1 {} +
cp "$phases" "$scratch/in/phases.sh"
cp "$script" "$scratch/in/script.sh"
printf '%s\n' 'root:x:0:0:Nix build user:/build:/noshell' 'nixbld:x:1000:100:Nix build user:/build:/noshell' \
  'nobody:x:65534:65534:Nobody:/:/noshell' > "$scratch/etc/passwd"
printf '%s\n' 'root:x:0:' 'nixbld:!:100:' 'nogroup:x:65534:' > "$scratch/etc/group"
printf '%s\n' '127.0.0.1 localhost' '::1 localhost' > "$scratch/etc/hosts"

binds=()
outputs=()
index=0
for arg in "$@"; do
  if [[ $arg != - && -e $arg ]]; then
    binds+=(--ro-bind "$(realpath "$arg")" "/arg/$index")
  elif [[ $arg != - ]]; then
    outputs+=("$index:$arg")
  fi
  index=$((index + 1))
done

sh=$(dirname "$BASH")/sh
# Test actions get the pinned CA bundle at the OS trust-store path.
etc=()
if [[ -n ${MIX_SANDBOX_CA_BUNDLE-} ]]; then
  etc+=(--ro-bind "$MIX_SANDBOX_CA_BUNDLE" /etc/ssl/certs/ca-certificates.crt)
fi
# Suites that sample cgroup limits (Lilly's collector) read the host's cgroup
# v2 root, read-only. It is not part of the action key (mix_test
# `host_cgroup`; contract mix-test-hermetic-postgres records the exception).
if [[ -n ${MIX_SANDBOX_CGROUP-} ]]; then
  etc+=(--ro-bind /sys/fs/cgroup /sys/fs/cgroup)
fi
# Buck2 does not kill a local action's process tree when its daemon exits
# (`buck2 kill`, a restart). Left running, a sandbox keeps writing to a
# scratch path the next daemon reuses, so this script watches for its own
# reparenting and kills bwrap, whose --die-with-parent and PID namespace
# then take every process in the sandbox with it.
parent=$PPID
env -i "$bwrap" --unshare-all --die-with-parent --hostname localhost --uid 1000 --gid 100 \
  --tmpfs / --dev /dev --proc /proc --tmpfs /tmp --tmpfs /dev/shm \
  --ro-bind /nix /nix --overlay-src /nix/store --tmp-overlay /nix/store \
  --bind "$scratch/build" /build --ro-bind "$scratch/src" /build-src --bind "$scratch/io" /io \
  --ro-bind "$scratch/in" /in --ro-bind "$scratch/etc/passwd" /etc/passwd \
  --ro-bind "$scratch/etc/group" /etc/group --ro-bind "$scratch/etc/hosts" /etc/hosts \
  --symlink "$sh" /bin/sh "${etc[@]}" "${binds[@]}" --chdir /build \
  "$BASH" --noprofile --norc -c 'source "$1"; source /in/phases.sh; source /in/script.sh' mix-action "$state" &
sandbox=$!
while kill -0 "$sandbox" 2>/dev/null; do
  read -r -a stat < "/proc/$$/stat"
  # Field 4 is the parent PID (the command name in field 2 has no spaces).
  if [[ ${stat[3]} != "$parent" ]]; then
    kill -KILL "$sandbox" 2>/dev/null || true
    exit 1
  fi
  sleep 1
done
wait "$sandbox"

for output in "${outputs[@]}"; do
  index=${output%%:*} path=${output#*:}
  [[ -e $scratch/io/$index ]] || { echo "mix_sandbox.sh: action wrote no output $index ($path)" >&2; exit 1; }
  rm -rf "$path"
  mkdir -p "$(dirname "$path")"
  cp -a "$scratch/io/$index" "$path"
done
