defmodule Enrico.Git do
  @moduledoc "Bounded, argument-vector Git operations against service-owned bare mirrors."

  @max_result 1_048_576
  @max_blob 16_777_216
  @max_path_scan 67_108_864
  @fetch_timeout 3_600_000
  @read_timeout 10_000
  @contention_wait 10_000
  @contention_backoff_ms 10
  @contention_backoff_cap_ms 250
  @owner ~r/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$/
  @repo ~r/^[A-Za-z0-9._-]{1,100}$/
  @ref ~r|^[A-Za-z0-9_][A-Za-z0-9_./+-]{0,199}$|

  @type reason ::
          :invalid_repository
          | :invalid_ref
          | :invalid_path
          | :missing
          | :too_large
          | :timeout
          | :git_failed
  @type result :: {:ok, binary()} | {:error, reason()}
  @typep native_result :: {:ok, binary()} | {:error, reason() | :contended}

  @spec valid_source?(term(), term()) :: boolean()
  def valid_source?(owner, repo) when is_binary(owner) and is_binary(repo) do
    Regex.match?(@owner, owner) and Regex.match?(@repo, repo) and
      not String.ends_with?(repo, ".git") and repo not in [".", ".."]
  end

  def valid_source?(_, _), do: false

  @spec valid_ref?(term()) :: boolean()
  def valid_ref?(ref) when is_binary(ref) do
    Regex.match?(@ref, ref) and not String.contains?(ref, ["..", "//", "@{", "/."]) and
      not String.ends_with?(ref, ["/", ".", ".lock"])
  end

  def valid_ref?(_), do: false

  @spec valid_path?(term()) :: boolean()
  def valid_path?(path) when is_binary(path) do
    byte_size(path) <= 1024 and not String.contains?(path, ["\0", "\n", "\r"]) and
      Enum.all?(Path.split(path), &(&1 not in ["..", "."])) and not String.starts_with?(path, "/")
  end

  def valid_path?(_), do: false

  # @cc [owner:ghuntley,label:security;recovery] git-fixed-public-source
  # Fetch MUST construct a credential-free github.com HTTPS URL from validated
  # owner/repo labels. No caller-controlled remote, helper, shell or protocol
  # may be used, and failure MUST preserve the last published mirror.

  # @cc [owner:ghuntley,label:recovery;capacity] refresh-retiring-owner-wait
  # Given a wait budget, each refresh step MUST retry, up to that bound, only
  # the native owner's pre-exec lock refusal, never a started command. The
  # budget defaults to zero so direct callers refuse an occupied writer at
  # once; administrative removal and reads always refuse immediately, and an
  # exhausted wait fails the attempt without effects.
  @spec refresh(binary(), binary(), binary(), non_neg_integer()) ::
          {:ok, binary()} | {:error, reason()}
  def refresh(root, owner, repo, wait \\ 0) do
    if valid_source?(owner, repo) do
      url = "https://github.com/#{owner}/#{repo}.git"

      if File.dir?(root) do
        with {:ok, _} <-
               run(
                 ["--git-dir=#{root}", "remote", "set-url", "origin", url],
                 @read_timeout,
                 @max_result,
                 false,
                 wait
               ),
             {:ok, previous} <- resolve(root, "HEAD", wait),
             :ok <- retain_head(root, previous, wait),
             {:ok, branch} <- remote_head(root, wait),
             {:ok, _} <-
               run(
                 [
                   "--git-dir=#{root}",
                   "fetch",
                   "--quiet",
                   "--atomic",
                   "--prune",
                   "origin",
                   "+refs/heads/*:refs/heads/*",
                   "+refs/tags/*:refs/tags/*"
                 ],
                 @fetch_timeout,
                 @max_result,
                 false,
                 wait
               ),
             {:ok, _} <-
               run(
                 ["--git-dir=#{root}", "symbolic-ref", "HEAD", branch],
                 @read_timeout,
                 @max_result,
                 false,
                 wait
               ),
             {:ok, head} <- resolve(root, "HEAD", wait),
             :ok <- retain_head(root, head, wait) do
          {:ok, head}
        end
      else
        temporary = root <> ".new"

        with :ok <- mutate(temporary, "rm", ["-rf", "--", temporary], wait),
             {:ok, _} <-
               run(
                 ["clone", "--quiet", "--mirror", url, temporary],
                 @fetch_timeout,
                 @max_result,
                 false,
                 wait
               ),
             {:ok, head} <- resolve(temporary, "HEAD", wait),
             :ok <- retain_head(temporary, head, wait),
             :ok <- mutate(root, "mv", ["-T", "--", temporary, root], wait) do
          {:ok, head}
        else
          _ ->
            remove(temporary)
            {:error, :git_failed}
        end
      end
    else
      {:error, :invalid_repository}
    end
  end

  # Bounds one refresh step's wait for an earlier worker lifetime's native
  # owner, which releases its locks only after reaping its process group
  # (itself bounded to two seconds once the caller has gone).
  @spec retiring_owner_wait() :: pos_integer()
  def retiring_owner_wait, do: @contention_wait

  @spec default_head(binary()) :: result()
  def default_head(root) do
    resolve(root, "HEAD")
  end

  # Keep every default head addressable when an upstream force-push makes it
  # unreachable from its branch before Marshall has published the next head.
  defp retain_head(root, sha, wait) do
    case run(
           ["--git-dir=#{root}", "update-ref", "refs/enrico/retained/#{sha}", sha],
           @read_timeout,
           @max_result,
           false,
           wait
         ) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp remote_head(root, wait) do
    with {:ok, output} <-
           run(
             ["--git-dir=#{root}", "ls-remote", "--symref", "origin", "HEAD"],
             @read_timeout,
             @max_result,
             false,
             wait
           ),
         [_, branch] <- Regex.run(~r/^ref: (refs\/heads\/[^\t\n]+)\tHEAD$/m, output),
         true <- valid_ref?(branch) do
      {:ok, branch}
    else
      _ -> {:error, :git_failed}
    end
  end

  @spec resolve(binary(), binary()) :: result()
  def resolve(root, ref), do: resolve(root, ref, 0)

  @spec resolve(binary(), binary(), non_neg_integer()) :: result()
  defp resolve(root, ref, wait) do
    if valid_ref?(ref) do
      with {:ok, value} <-
             run(
               [
                 "--git-dir=#{root}",
                 "rev-parse",
                 "--verify",
                 "--end-of-options",
                 "#{ref}^{commit}"
               ],
               @read_timeout,
               @max_result,
               false,
               wait
             ),
           sha = String.trim(value),
           true <- Regex.match?(~r/^[0-9a-f]{40,64}$/, sha) do
        {:ok, sha}
      else
        _ -> {:error, :invalid_ref}
      end
    else
      {:error, :invalid_ref}
    end
  end

  @spec inspect(binary(), binary(), binary(), binary()) :: result()
  def inspect(root, operation, ref, path) do
    with {:ok, sha} <- resolve(root, ref),
         true <- valid_path?(path) do
      prefix = ["--git-dir=#{root}"]

      case operation do
        "tree" ->
          run(
            prefix ++ ["ls-tree", "-z", if(path == "", do: sha, else: "#{sha}:#{path}")],
            @read_timeout
          )

        "blob" ->
          blob(prefix, sha, path)

        "history" ->
          run(
            prefix ++ ["log", "-n", "50", "--format=%H%x09%at%x09%s", sha] ++ pathspec(path),
            @read_timeout
          )

        "diff" ->
          run(
            prefix ++
              ["show", "--format=fuller", "--no-ext-diff", "--no-renames", sha] ++ pathspec(path),
            @read_timeout
          )

        "blame" ->
          if(path == "",
            do: {:error, :invalid_path},
            else: run(prefix ++ ["blame", "--line-porcelain", sha, "--", path], @read_timeout)
          )

        "refs" ->
          run(
            prefix ++
              [
                "for-each-ref",
                "--format=%(refname:short)%09%(objectname)",
                "refs/heads",
                "refs/tags"
              ],
            @read_timeout
          )

        _ ->
          {:error, :invalid_path}
      end
    else
      false -> {:error, :invalid_path}
      other -> other
    end
  end

  @spec search(binary(), binary(), binary(), binary()) :: result()
  def search(root, ref, kind, query) do
    with {:ok, sha} <- resolve(root, ref),
         true <-
           is_binary(query) and byte_size(query) in 1..128 and
             not String.contains?(query, ["\0", "\n", "\r"]) do
      prefix = ["--git-dir=#{root}"]

      case kind do
        "content" ->
          run(
            prefix ++ ["grep", "-I", "-F", "-n", "--max-count=100", "-e", query, sha],
            @read_timeout,
            @max_result,
            true
          )

        "commits" ->
          run(
            prefix ++
              [
                "log",
                "-n",
                "100",
                "--format=%H%x09%at%x09%s",
                "--fixed-strings",
                "--grep",
                query,
                sha
              ],
            @read_timeout
          )

        "paths" ->
          search_paths(prefix, sha, query)

        _ ->
          {:error, :invalid_path}
      end
    else
      false -> {:error, :invalid_path}
      other -> other
    end
  end

  @spec remove(binary()) :: :ok | {:error, :git_failed}
  def remove(root) do
    mutate(root, "rm", ["-rf", "--", root], 0)
  end

  # @cc [owner:ghuntley,label:recovery] git-filesystem-write-owner
  # Cleanup, publication and removal MUST acquire the same native writer lock
  # as Git before any filesystem effect. Occupied authority MUST refuse safely.
  @spec mutate(binary(), binary(), [binary()], non_neg_integer()) :: :ok | {:error, :git_failed}
  defp mutate(root, utility, arguments, wait) do
    executable = System.find_executable(utility) || raise ArgumentError

    attempt = fn ->
      port =
        open_native(root, "exclusive", executable, arguments, @read_timeout, @max_result, [])

      collect(
        port,
        <<>>,
        System.monotonic_time(:millisecond) + @read_timeout,
        @max_result,
        false
      )
    end

    case await_owner(attempt, wait) do
      {:ok, _} -> :ok
      _ -> {:error, :git_failed}
    end
  rescue
    _ -> {:error, :git_failed}
  end

  # The native owner exits 75 with no output only when it could not take the
  # repository or admission lock, before any command or filesystem effect, so
  # repeating that refusal cannot duplicate work. A retiring owner from a
  # killed worker releases its locks once its private process group is reaped.
  @spec await_owner((-> native_result()), non_neg_integer()) :: result()
  defp await_owner(attempt, wait) do
    await_owner(
      attempt,
      System.monotonic_time(:millisecond) + wait,
      @contention_backoff_ms
    )
  end

  @spec await_owner((-> native_result()), integer(), pos_integer()) :: result()
  defp await_owner(attempt, deadline, delay) do
    case attempt.() do
      {:error, :contended} ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining > 0 do
          Process.sleep(min(delay, remaining))
          await_owner(attempt, deadline, min(delay * 2, @contention_backoff_cap_ms))
        else
          {:error, :git_failed}
        end

      other ->
        other
    end
  end

  defp blob(prefix, sha, path) when path != "" do
    object = "#{sha}:#{path}"

    with {:ok, size} <- run(prefix ++ ["cat-file", "-s", object], @read_timeout),
         {bytes, ""} <- Integer.parse(String.trim(size)),
         true <- bytes <= @max_blob do
      run(prefix ++ ["cat-file", "blob", object], @read_timeout, @max_blob)
    else
      false -> {:error, :too_large}
      _ -> {:error, :missing}
    end
  end

  defp blob(_, _, _), do: {:error, :invalid_path}

  defp pathspec(""), do: []
  defp pathspec(path), do: ["--", path]

  # Path search scans a bounded Git stream and retains only the first 100
  # matches, so large trees do not have to fit in the HTTP response budget.
  defp search_paths(prefix, sha, query) do
    port =
      open_git(
        prefix ++ ["ls-tree", "-r", "-z", "--name-only", sha],
        @read_timeout,
        @max_path_scan
      )

    scan_paths(port, query, <<>>, [], 0, System.monotonic_time(:millisecond) + @read_timeout)
  rescue
    _ -> {:error, :git_failed}
  end

  defp scan_paths(port, query, pending, matches, total, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        if total + byte_size(chunk) > @max_path_scan do
          Port.close(port)
          {:error, :too_large}
        else
          parts = :binary.split(pending <> chunk, <<0>>, [:global])
          pending = List.last(parts)

          matches =
            parts
            |> Enum.drop(-1)
            |> Enum.reduce_while(matches, fn path, found ->
              if length(found) >= 100,
                do: {:halt, found},
                else:
                  if(:binary.match(path, query) != :nomatch,
                    do: {:cont, [path | found]},
                    else: {:cont, found}
                  )
            end)

          if length(matches) >= 100 do
            Port.close(port)
            path_result(matches)
          else
            scan_paths(port, query, pending, matches, total + byte_size(chunk), deadline)
          end
        end

      {^port, {:exit_status, 0}} ->
        path_result(matches)

      {^port, {:exit_status, 124}} ->
        {:error, :timeout}

      {^port, {:exit_status, 125}} ->
        {:error, :too_large}

      {^port, {:exit_status, _}} ->
        {:error, :git_failed}
    after
      remaining ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  defp path_result(matches) do
    value = matches |> Enum.reverse() |> Enum.join("\n")
    if byte_size(value) <= @max_result, do: {:ok, value}, else: {:error, :too_large}
  end

  @spec run([binary()], pos_integer(), pos_integer(), boolean(), non_neg_integer()) :: result()
  defp run(args, timeout, limit \\ @max_result, allow_no_match \\ false, wait \\ 0) do
    Overalls.Diagnostics.Tracing.with_span("enrico.git.utility", [], fn ->
      await_owner(fn -> run_native(args, timeout, limit, allow_no_match) end, wait)
    end)
  end

  @spec run_native([binary()], pos_integer(), pos_integer(), boolean()) :: native_result()
  defp run_native(args, timeout, limit, allow_no_match) do
    port = open_git(args, timeout, limit)

    collect(port, <<>>, System.monotonic_time(:millisecond) + timeout, limit, allow_no_match)
  rescue
    _ -> {:error, :git_failed}
  end

  # @cc [owner:ghuntley,label:recovery;capacity] git-native-owner
  # Git MUST execute under the native owner with stable repository and eight-slot
  # admission locks. Caller death and output/deadline refusal MUST leave cleanup
  # under that owner before a successor can acquire conflicting write authority.
  @spec open_git([binary()], pos_integer(), pos_integer()) :: port()
  defp open_git(args, timeout, limit) do
    git = System.find_executable("git") || raise ArgumentError
    {root, mode} = native_scope(args)

    command = [
      "-c",
      "credential.helper=",
      "-c",
      "http.followRedirects=false",
      "-c",
      "gc.auto=0",
      "-c",
      "pack.threads=2",
      "-c",
      "maintenance.auto=false" | args
    ]

    open_native(root, mode, git, command, timeout, limit, native_environment())
  end

  @spec native_environment() :: [{charlist(), charlist()}]
  defp native_environment do
    base = [
      {~c"GIT_CONFIG_NOSYSTEM", ~c"1"},
      {~c"GIT_CONFIG_GLOBAL", ~c"/dev/null"},
      {~c"GIT_ALLOW_PROTOCOL", ~c"https"},
      {~c"GIT_TERMINAL_PROMPT", ~c"0"}
    ]

    case System.get_env("GIT_SSL_CAINFO") do
      nil -> base
      ca_file -> [{~c"GIT_SSL_CAINFO", String.to_charlist(ca_file)} | base]
    end
  end

  @spec open_native(binary(), binary(), binary(), [binary()], pos_integer(), pos_integer(), [
          {charlist(), charlist()}
        ]) :: port()
  defp open_native(root, mode, executable, command, timeout, limit, environment) do
    owner = System.find_executable("enrico-git-owner") || raise ArgumentError
    repository = root |> Path.basename() |> String.replace_suffix(".git.new", ".git")

    parameters = [
      Integer.to_string(timeout),
      Integer.to_string(limit),
      Path.dirname(root),
      repository,
      mode,
      executable
    ]

    Port.open({:spawn_executable, owner}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: parameters ++ command,
      env: environment
    ])
  end

  @spec native_scope([binary()]) :: {binary(), binary()}
  defp native_scope(["clone", "--quiet", "--mirror", _url, root]), do: {root, "exclusive"}

  defp native_scope(["--git-dir=" <> root, operation | _]) do
    mode =
      if operation in ["fetch", "remote", "update-ref", "symbolic-ref"],
        do: "exclusive",
        else: "shared"

    {root, mode}
  end

  defp collect(port, output, deadline, limit, allow_no_match) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        if byte_size(output) + byte_size(chunk) > limit do
          Port.close(port)
          {:error, :too_large}
        else
          collect(port, output <> chunk, deadline, limit, allow_no_match)
        end

      {^port, {:exit_status, 0}} ->
        {:ok, output}

      {^port, {:exit_status, 1}} when allow_no_match and output == "" ->
        {:ok, ""}

      {^port, {:exit_status, 124}} ->
        {:error, :timeout}

      {^port, {:exit_status, 125}} ->
        {:error, :too_large}

      {^port, {:exit_status, 75}} when output == "" ->
        {:error, :contended}

      {^port, {:exit_status, _}} ->
        {:error, :git_failed}
    after
      remaining ->
        Port.close(port)
        {:error, :timeout}
    end
  end
end
