# Mix action phases, sourced inside the sandbox after the mixRelease shell
# state (ADR-0269). Contracts: buck/CONTRACTS. Paths: /build is the work
# directory, /build-src/source the declared sources, /arg/N inputs and /io/N
# outputs (see mix_sandbox.sh).
set -eu -o pipefail

export NIX_BUILD_TOP=/build TMPDIR=/build TEMPDIR=/build TMP=/build TEMP=/build
export HOME=/homeless-shelter NIX_BUILD_CORES=4 NIX_LOG_FD=2

# Same flags stdenv derives from $out; a non-release action names no output.
_mix_output_flags() {
  local hash=$1
  export NIX_CFLAGS_COMPILE=" -frandom-seed=${hash:0:10}${mixStateCflags}"
  export NIX_LDFLAGS="-rpath $out/lib "
}

# The first 32 characters of a store path's basename, for reference scans.
_mix_store_hashes() {
  grep -raohE '/nix/store/[0-9a-df-np-sv-z]{32}' "$@" | cut -c12- | sort -u || true
}

# Contracts mix-release-parity mix-release-self-reference mix-release-runtime-refs: see buck/CONTRACTS.
mix_release() {
  # The Nix builder sets TERM for every build. With it, Elixir loads other
  # modules, which shifts atom indices and so the map order Mix.Release
  # writes into sys.config (contract mix-release-parity).
  export TERM=xterm-256color
  export out="/nix/store/${out_hash}-${out_name}"
  prefix=$out
  declare -gA outputs=([out]="$out")
  _mix_output_flags "$random_seed"
  src=/build-src/source
  buildPhase=mixCompileHook
  installPhase=mixReleaseInstallHook
  runHook postHook
  genericBuild

  # Any ELF that names the placeholder would break when assembly rewrites it.
  local file
  while IFS= read -r -d '' file; do
    if [[ $(head -c 4 "$file" | od -An -c | tr -d ' ') == 177ELF ]]; then
      echo "mix_release: $file embeds the output path" >&2
      exit 1
    fi
  done < <(grep -rlZF -- "$out" "$out" || true)

  local declared=" " ref
  for ref in $declared_refs; do declared+="${ref:11:32} "; done
  : > /io/1
  for ref in $(_mix_store_hashes "$out"); do
    [[ $ref == "$out_hash" ]] && continue
    if [[ $declared != *" $ref "* ]]; then
      echo "mix_release: undeclared runtime reference /nix/store/$ref" >&2
      exit 1
    fi
    printf '/nix/store/%s\n' "$ref" >> /io/1
  done
  cp -a "$out" /io/0
  find /io/0 -exec touch -h -d @1 {} +
}

# Shared set-up for actions that compile or reuse a compiled project.
_mix_workspace() {
  # These actions install nothing; a single output keeps stdenv's multiple
  # output hooks inert.
  export out=/build/out
  declare -gA outputs=([out]="$out")
  runHook postHook
  mkdir -p /build/source
  cp -pr /build-src/source/. /build/source/
  chmod -R u+w /build/source
  cd "/build/source/$project"
}

_mix_dependencies() {
  sourceRoot="source/$project"
  ( cd /build && runHook postUnpack )
  export MIX_DEPS_PATH=/build/deps
  if [[ -d $MIX_DEPS_PATH/.overalls-elixir-make ]]; then
    export ELIXIR_MAKE_CACHE_DIR=$MIX_DEPS_PATH/.overalls-elixir-make
  fi
  # Reject a stale fixed-output fetch rather than compiling old deps against
  # a new lock (as release-dependency-hashes does for releases).
  cmp mix.lock "$MIX_DEPS_PATH/.overalls-mix.lock"
  # preConfigureHooks include mixBuildDirHook, which links hex and rebar
  # into _build as mixRelease does.
  runHook preConfigure
  ln -s "$MIX_DEPS_PATH" ./deps
}

# Contracts mix-compile-shared-build: see buck/CONTRACTS.
mix_compile() {
  _mix_workspace
  _mix_dependencies
  mix deps.compile --no-deps-check --skip-umbrella-children
  mix compile --no-deps-check --warnings-as-errors
  mkdir -p /io/0
  cp -a "_build/$MIX_BUILD_PREFIX" /io/0/build
  cp -a /build/deps /io/0/deps
}

# Fixed-output fetches drop .git, so tasks that check deps without
# --no-deps-check (Dialyxir) see git deps as out of date. Record each locked
# git dep's origin and revision as Mix reads them; the fetch hash and the
# mix.lock comparison already authenticate the contents.
_mix_git_locks() {
  [[ -n ${OVERALLS_GIT_BIN-} ]] || return 0
  export PATH="$OVERALLS_GIT_BIN:$PATH"
  elixir -e '
    {lock, _} = Code.eval_file("mix.lock")
    deps = System.fetch_env!("MIX_DEPS_PATH")
    for {name, {:git, url, rev, _}} <- lock, dir = Path.join(deps, to_string(name)), File.dir?(dir) do
      {_, 0} = System.cmd("git", ["init", "--quiet", dir])
      {_, 0} = System.cmd("git", ["--git-dir", Path.join(dir, ".git"), "remote", "add", "origin", url])
      File.write!(Path.join([dir, ".git", "HEAD"]), rev <> "\n")
    end
  '
}

_mix_restore() {
  _mix_workspace
  cp -a /arg/0/deps /build/deps
  chmod -R u+w /build/deps
  export MIX_DEPS_PATH=/build/deps
  if [[ -d $MIX_DEPS_PATH/.overalls-elixir-make ]]; then
    export ELIXIR_MAKE_CACHE_DIR=$MIX_DEPS_PATH/.overalls-elixir-make
  fi
  mkdir -p _build
  cp -a /arg/0/build "_build/$MIX_BUILD_PREFIX"
  chmod -R u+w _build
  # The restored _build already holds mixBuildDirHook's links; run only the
  # project's preConfigure lines.
  local hooks=("${preConfigureHooks[@]}")
  preConfigureHooks=()
  runHook preConfigure
  preConfigureHooks=("${hooks[@]}")
  ln -s "$MIX_DEPS_PATH" ./deps
  _mix_git_locks
}

# Dialyxir keeps the core PLT under MIX_HOME and the project PLT in _build.
_mix_plt_paths() {
  export MIX_HOME=/build/.mix
  mkdir -p "$MIX_HOME"
}

# Dialyxir runs `compile` and then reloads dependency paths, recompiling the
# path dependencies (Hegel). That dependency compile prunes the code path to
# the dependency's applications, and the later `compile` is already done, so
# OTP extra_applications such as :ssh go missing. With --no-compile the
# project's compile runs after the dependency reload and restores them.
# Contracts mix-check-subtargets: see buck/CONTRACTS.
mix_plt() {
  _mix_restore
  _mix_plt_paths
  mix do deps.loadpaths --no-deps-check + dialyzer --plt --no-compile
  mkdir -p /io/1/core /io/1/project
  cp -a "$MIX_HOME"/*.plt* /io/1/core/ 2>/dev/null || true
  cp -a "_build/$MIX_BUILD_PREFIX"/*.plt* /io/1/project/
}

mix_check() {
  local command=$1
  _mix_restore
  if [[ -d /arg/2 ]]; then
    _mix_plt_paths
    cp -a /arg/2/core/. "$MIX_HOME/" 2>/dev/null || true
    cp -a /arg/2/project/. "_build/$MIX_BUILD_PREFIX/"
    chmod -R u+w "$MIX_HOME" "_build/$MIX_BUILD_PREFIX"
  fi
  # shellcheck disable=SC2086 # the command is a reviewed Mix task line
  if ! mix do deps.loadpaths --no-deps-check + $command > /io/1 2>&1; then
    cat /io/1 >&2
    exit 1
  fi
}

# Contracts mix-test-hermetic-postgres: see buck/CONTRACTS.
_mix_postgres() {
  export PGDATA=/build/pg PGHOST=/build/pgs PGUSER=postgres PGPASSWORD=postgres
  mkdir -p "$PGHOST"
  "$postgres_bin/initdb" --auth=trust --username=postgres --no-sync -D "$PGDATA" > /build/initdb.log
  "$postgres_bin/pg_ctl" -D "$PGDATA" -l /build/postgres.log -w start \
    -o "-k $PGHOST -c listen_addresses= -c fsync=off -c max_connections=200" > /dev/null
}

# Contract mix-test-known-failures: see buck/CONTRACTS. $known_failures holds
# one entry per line: `Module` (every failure of that module) or
# `Module: test name` (that test alone). Writes /io/1/known.txt, one
# `failing<TAB>entry` or `passing<TAB>entry` line per entry, and succeeds only
# when every failure in the log matches an entry.
_mix_known_failures() {
  local status=$1 header module name entry matched unknown=0 failures=0
  local -a entries=() hits=()
  mapfile -t entries <<< "$known_failures"
  for entry in "${entries[@]}"; do hits+=(0); done
  # ExUnit failure headers: "  N) test name (Module)" or "  N) Module: failure on setup_all ...".
  while IFS= read -r header; do
    failures=$((failures + 1))
    if [[ $header =~ ^\ +[0-9]+\)\ (.*)\ \(([A-Za-z0-9_.]+)\)$ ]]; then
      name=${BASH_REMATCH[1]} module=${BASH_REMATCH[2]}
    elif [[ $header =~ ^\ +[0-9]+\)\ ([A-Za-z0-9_.]+):\ (.*)$ ]]; then
      module=${BASH_REMATCH[1]} name=${BASH_REMATCH[2]}
    else
      module="" name=$header
    fi
    matched=false
    for i in "${!entries[@]}"; do
      entry=${entries[$i]}
      if [[ -n $module && ( $entry == "$module" || $entry == "$module: $name" ) ]]; then
        hits[i]=1 matched=true
      fi
    done
    if ! $matched; then
      unknown=$((unknown + 1))
      echo "mix_test: not a known failure: $header" >&2
    fi
  done < <(grep -E '^ +[0-9]+\) ' /io/1/test.log || true)
  : > /io/1/known.txt
  for i in "${!entries[@]}"; do
    if ((hits[i])); then
      printf 'failing\t%s\n' "${entries[$i]}" >> /io/1/known.txt
    else
      printf 'passing\t%s\n' "${entries[$i]}" >> /io/1/known.txt
    fi
  done
  # A non-zero exit with no failure headers (a crash, a compile error) is
  # never a known failure.
  [[ $status == 0 ]] || { ((failures > 0)) && ((unknown == 0)); }
}

# Contracts mix-test-seeds-explicit: see buck/CONTRACTS. Sets _mix_seed and
# the Hegel environment from the shard's inputs. The sandbox clears the
# environment, so CI=true selects Hegel's `ci` profile explicitly: no
# database and no wall-clock TooSlow health check, which would make a verdict
# depend on machine load. The seed is the 32-bit FNV-1a hash of the shard's
# input digest (every source file under /build-src and the test arguments)
# and `[mix] test_salt`, and drives both ExUnit and HEGEL_SEED: a cached
# verdict is exactly what a rerun of the same inputs reaches, every changed
# input explores new draws, and a salt reruns everything with new ones. The
# engine reads its environment once per VM.
_mix_test_seeds() {
  export CI=true HEGEL_DATABASE=disabled
  unset HEGEL_DERANDOMIZE
  if [[ -n ${test_salt-} && ! $test_salt =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
    echo "mix_test: test_salt must be 1-64 characters of [A-Za-z0-9._-]" >&2
    exit 1
  fi
  local digest
  digest=$(
    {
      (cd /build-src/source && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum)
      printf 'arg %s\n' "$@"
    } | sha256sum
  )
  digest=${digest%% *}
  local input="${test_salt-}:$digest" hash=2166136261 i char
  for ((i = 0; i < ${#input}; i++)); do
    printf -v char '%d' "'${input:i:1}"
    hash=$(((hash ^ char) * 16777619 & 0xffffffff))
  done
  # ExUnit treats seed 0 as "do not shuffle"; keep every run shuffled.
  _mix_seed=$((hash == 0 ? 1 : hash))
  export HEGEL_SEED=$_mix_seed
  _mix_seed_line="mix_test: test_salt='${test_salt-}' inputs=$digest exunit --seed $_mix_seed, hegel ci profile HEGEL_SEED=$_mix_seed, HEGEL_DATABASE=disabled"
}

# Contracts mix-test-cacheable-result: see buck/CONTRACTS.
mix_test() {
  _mix_restore
  if [[ -n ${postgres_bin-} ]]; then _mix_postgres; fi
  # The sandbox has no /usr/bin/env, so test helper scripts (Enrico's
  # controlled git) get store interpreters, as in a Nix check.
  if [[ -d test ]]; then patchShebangs test > /dev/null; fi
  mkdir -p /io/1
  local seed
  _mix_test_seeds "$@"
  seed=$_mix_seed
  local status=0
  printf '%s\n' "$_mix_seed_line" > /io/1/test.log
  # A hard bound per shard (contract mix-test-sharded): a hung test or
  # cleanup fails the shard in test_timeout instead of holding it for hours.
  timeout --signal=TERM --kill-after=30s "${test_timeout:-45m}" \
    mix do deps.loadpaths --no-deps-check + test --seed "$seed" "$@" >> /io/1/test.log 2>&1 || status=$?
  if [[ $status == 124 || $status == 137 ]]; then
    echo "mix_test: the shard exceeded its ${test_timeout:-45m} bound" >> /io/1/test.log
  fi
  # The known_failures shard: a failure listed in known_failures is reported,
  # not fatal; any other failure still fails the shard.
  if [[ -n ${known_failures-} ]] && _mix_known_failures "$status"; then status=0; fi
  printf '%s\n' "$status" > /io/1/status
  if [[ -d _build/covenant ]]; then cp -a _build/covenant /io/1/covenant; fi
  if [[ -n ${postgres_bin-} ]]; then "$postgres_bin/pg_ctl" -D "$PGDATA" -m immediate stop > /dev/null; fi
  # A failed suite fails this action, so no cache keeps the failure as a
  # successful result; Buck2 discards a failed action's outputs.
  if [[ $status != 0 ]]; then
    # Every failed test by name, then the end of the log.
    grep -E '^ +[0-9]+\) (test|property|doctest|describe) ' /io/1/test.log >&2 || true
    tail -n 200 /io/1/test.log >&2
    echo "mix_test: the suite exited with status $status" >&2
    echo "$_mix_seed_line" >&2
    echo "mix_test: reproduce with -c mix.test_salt='${test_salt-}', or outside Buck2 with" \
      "CI=true HEGEL_DATABASE=disabled HEGEL_SEED=$HEGEL_SEED mix test --seed $seed <the shard's files>" >&2
    exit 1
  fi
}

# Contracts mix-test-sharded: see buck/CONTRACTS. /arg/2 onwards are the
# shards' passing records; each shard's Covenant results file is kept under
# its own name, and covenant.check reads the union of their tests.
mix_covenant() {
  local shards=$1 index file name
  _mix_restore
  mkdir -p _build/covenant/results
  for ((index = 1; index <= shards; index++)); do
    local results=/arg/$((index + 1))/covenant/results
    [[ -d $results ]] || continue
    for file in "$results"/*.json; do
      [[ -e $file ]] || continue
      name=$(basename "$file" .json)
      cp "$file" "_build/covenant/results/$name.shard-$index.json"
    done
  done
  if ! mix do deps.loadpaths --no-deps-check + covenant.check --no-run > /io/1 2>&1; then
    cat /io/1 >&2
    exit 1
  fi
}
