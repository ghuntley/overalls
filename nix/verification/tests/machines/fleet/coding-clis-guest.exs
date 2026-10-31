defmodule FleetCodingCLIsGuest.Failure do
  @moduledoc false

  @typedoc "Closed failure classes; never terminal bytes or exception text."
  @type reason ::
          :invalid_arguments
          | :connect_failed
          | :shell_not_ready
          | :command_failed
          | :command_timed_out
          | :terminal_unavailable

  defexception phase: :setup, reason: :command_failed, status: nil

  @type t :: %__MODULE__{
          phase: atom(),
          reason: reason(),
          status: non_neg_integer() | nil
        }

  @impl true
  @spec message(t()) :: String.t()
  def message(%__MODULE__{}), do: "Coding CLI guest assertion failed; terminal bytes withheld"
end

defmodule FleetCodingCLIsGuest do
  @moduledoc false
  alias FleetCodingCLIsGuest.Failure
  alias FleetTerminal, as: Terminal

  @type mode :: :prepare | :terminal | :gc | :customer | :tls_refusal | :token_count
  @native_timeout_seconds 180
  @private_directory "$HOME/.local/state/overalls-coding-cli-fixture"

  # @cc [owner:ghuntley,label:verification;security] coding-clis-native-guest-account
  # Inference probes MUST execute the image's normal binaries and configuration
  # in a real canonical account PTY. Preparation MUST obtain that account from
  # verified roster reconciliation; no synthetic account, provider configuration,
  # credentials or routing authority may be installed by this fixture.
  @spec run(String.t(), String.t(), String.t()) :: :ok
  def run(mode, placement, username) do
    unless OverallsProtocol.uuid?(placement) and
             Regex.match?(~r/\A[a-z][a-z0-9_-]{0,30}\z/, username) and username != "root",
           do: raise(Failure, phase: :setup, reason: :invalid_arguments)

    action = parse_mode(mode)
    account = if action in [:prepare, :gc], do: "root", else: username
    socket = classified(:connect, :connect_failed, fn -> Terminal.connect(placement, account) end)

    try do
      :ok = classified(:shell_ready, :shell_not_ready, fn -> Terminal.ready(socket, 120_000) end)
      dispatch(socket, action, username)
    after
      Terminal.close(socket)
    end
  end

  # Fixture terminal helpers raise free-form errors; only a closed class leaves.
  @spec classified(atom(), Failure.reason(), (-> {:ok, term()} | :ok)) :: term()
  defp classified(phase, reason, fun) do
    case fun.() do
      {:ok, value} -> value
      :ok -> :ok
      _ -> raise Failure, phase: phase, reason: reason
    end
  rescue
    error in Failure -> reraise error, __STACKTRACE__
    _ -> raise Failure, phase: phase, reason: reason
  end

  @spec parse_mode(String.t()) :: mode()
  defp parse_mode("prepare"), do: :prepare
  defp parse_mode("terminal"), do: :terminal
  defp parse_mode("gc"), do: :gc
  defp parse_mode("customer"), do: :customer
  defp parse_mode("tls-refusal"), do: :tls_refusal
  defp parse_mode("token-count"), do: :token_count
  defp parse_mode(_), do: raise(Failure, phase: :setup, reason: :invalid_arguments)

  @spec dispatch(Terminal.t(), mode(), String.t()) :: :ok
  defp dispatch(socket, :prepare, username) do
    # Separate phases name whether the verified roster reconciliation or the
    # resulting local account failed, without returning guest output.
    command(
      socket,
      :prepare_roster,
      "test \"$(id -u)\" = 0 && " <>
        "if test -x /run/overalls-ssh-authorize; then authorize=/run/overalls-ssh-authorize; " <>
        "else authorize=/usr/local/bin/overalls-ssh-authorize; fi && " <>
        "\"$authorize\" ensure #{username}",
      60_000
    )

    command(
      socket,
      :prepare_account,
      "uid=$(id -u #{username}) && test \"$uid\" -ge 200000 && test \"$uid\" -le 999999 && " <>
        "test \"$(getent passwd #{username} | cut -d: -f6)\" = /home/#{username} && " <>
        "test -d /home/#{username} && test \"$(stat -c %u /home/#{username})\" = \"$uid\"",
      60_000
    )
  end

  defp dispatch(socket, :gc, _username) do
    command(socket, :gc, "test \"$(id -u)\" = 0 && nix-collect-garbage -d", 180_000)
    versions_and_help(socket)
  end

  defp dispatch(socket, mode, username)
       when mode in [:terminal, :customer, :tls_refusal, :token_count] do
    command(
      socket,
      :account,
      "test \"$(id -un)\" = #{username} && test \"$HOME\" = /home/#{username} && " <>
        "test -r /etc/ssl/certs/ca-certificates.crt && " <>
        "test \"$CODEX_CA_CERTIFICATE\" = /etc/ssl/certs/ca-certificates.crt && " <>
        "test \"$SSL_CERT_FILE\" = /etc/ssl/certs/ca-certificates.crt && " <>
        "test \"$NODE_EXTRA_CA_CERTS\" = /etc/ssl/certs/ca-certificates.crt && " <>
        "umask 077 && mkdir -p #{@private_directory} && " <>
        "test \"$(stat -c %u #{@private_directory})\" = \"$(id -u)\" && " <>
        "chmod 0700 #{@private_directory}"
    )

    versions_and_help(socket)

    case mode do
      :terminal -> inference(socket)
      :customer -> customer_refusal(socket)
      :tls_refusal -> tls_refusal(socket)
      :token_count -> token_count(socket)
    end
  end

  @spec versions_and_help(Terminal.t()) :: :ok
  defp versions_and_help(socket) do
    command(
      socket,
      :codex_version,
      "test \"$(timeout --foreground -k 5 30 codex --version)\" = 'codex-cli 0.149.0'",
      45_000
    )

    command(
      socket,
      :claude_version,
      "timeout --foreground -k 5 30 claude --version | grep -Eq '^2\\.1\\.238 \\(Claude Code\\)$'",
      45_000
    )

    command(socket, :codex_help, "timeout --foreground -k 5 30 codex --help >/dev/null", 45_000)
    command(socket, :claude_help, "timeout --foreground -k 5 30 claude --help >/dev/null", 45_000)
  end

  @spec inference(Terminal.t()) :: :ok
  defp inference(socket) do
    command(
      socket,
      :codex,
      "umask 077 && rm -f #{private_file("codex-last-message.txt")} && " <>
        "#{codex_command()} >#{private_file("codex.log")} 2>&1 && " <>
        "grep -Fq 'fixture codex reply' #{private_file("codex-last-message.txt")}",
      native_deadline()
    )

    command(
      socket,
      :claude,
      "umask 077 && #{claude_command()} >#{private_file("claude.log")} 2>&1 && " <>
        "grep -Fq 'fixture claude reply' #{private_file("claude.log")}",
      native_deadline()
    )
  end

  @spec customer_refusal(Terminal.t()) :: :ok
  defp customer_refusal(socket) do
    command(
      socket,
      :customer_codex,
      refusal(codex_command(), "customer-codex.log"),
      native_deadline()
    )

    command(
      socket,
      :customer_claude,
      refusal(claude_command(), "customer-claude.log"),
      native_deadline()
    )

    command(
      socket,
      :customer_client_refusal,
      "grep -Eiq '403|forbidden' #{private_file("customer-codex.log")} #{private_file("customer-codex.log.stderr")} && " <>
        "grep -Eiq '403|forbidden' #{private_file("customer-claude.log")} #{private_file("customer-claude.log.stderr")}",
      15_000
    )

    command(
      socket,
      :customer_routes,
      "test \"$(curl --noproxy '*' --silent --output /dev/null --write-out '%{http_code}' --max-time 15 " <>
        "--header 'Content-Type: application/json' --data '{}' " <>
        "https://llm.internal/openai/v1/responses)\" = 403 && " <>
        "test \"$(curl --noproxy '*' --silent --output /dev/null --write-out '%{http_code}' --max-time 15 " <>
        "--header 'Content-Type: application/json' --data '{}' " <>
        "'https://llm.internal/anthropic/v1/messages?beta=true')\" = 403",
      45_000
    )
  end

  @spec tls_refusal(Terminal.t()) :: :ok
  defp tls_refusal(socket) do
    bad_ca = private_file("invalid-ca.pem")
    unrelated_ca = private_file("unrelated-ca.pem")
    empty_ca_directory = private_file("empty-ca")
    public_ca = File.read!("/etc/fleet-coding-clis-untrusted-ca.pem") |> Base.encode64()

    command(
      socket,
      :tls_unrelated_root,
      "umask 077 && printf %s #{public_ca} | base64 -d >#{unrelated_ca} && " <>
        "mkdir -p #{empty_ca_directory} && " <>
        "curl --noproxy '*' --silent --output /dev/null --max-time 15 " <>
        "--cacert #{unrelated_ca} --capath #{empty_ca_directory} " <>
        "https://llm.internal/openai/v1/models; status=$?; test \"$status\" = 60"
    )

    command(
      socket,
      :tls_hostname,
      "address=$(getent ahostsv4 llm.internal | awk 'NR == 1 {print $1}') && " <>
        "test -n \"$address\" && " <>
        "curl --noproxy '*' --silent --output /dev/null --max-time 15 " <>
        "--cacert /etc/ssl/certs/ca-certificates.crt " <>
        "--resolve \"wrong.internal:443:$address\" https://wrong.internal/openai/v1/models; " <>
        "status=$?; test \"$status\" = 60"
    )

    command(
      socket,
      :tls_invalid_bundle,
      "umask 077 && printf 'invalid fixture CA\\n' >#{bad_ca} && " <>
        "curl --noproxy '*' --silent --output /dev/null --max-time 15 --cacert #{bad_ca} " <>
        "https://llm.internal/openai/v1/models; status=$?; " <>
        "test \"$status\" = 77"
    )

    command(
      socket,
      :tls_codex,
      # Codex retries connection failures without a bound by default. Limit only
      # this negative probe so a valid unrelated root returns a native refusal.
      refusal(
        "CODEX_CA_CERTIFICATE=#{unrelated_ca} SSL_CERT_FILE=#{unrelated_ca} SSL_CERT_DIR=#{empty_ca_directory} " <>
          codex_command(
            "--disable unbounded_connection_retries " <>
              "-c model_providers.ziggy.request_max_retries=0 " <>
              "-c model_providers.ziggy.stream_max_retries=0 "
          ),
        "tls-codex.log"
      ),
      native_deadline()
    )

    command(
      socket,
      :tls_codex_connection,
      "grep -Eiq 'connection failed|error sending request' #{private_file("tls-codex.log.stderr")}",
      15_000
    )
  end

  @spec token_count(Terminal.t()) :: :ok
  defp token_count(socket) do
    command(
      socket,
      :token_count,
      "curl --noproxy '*' --fail --silent --max-time 15 --header 'Content-Type: application/json' " <>
        "--data '{\"model\":\"fixture-model\",\"messages\":[{\"role\":\"user\",\"content\":\"fixture count\"}]}' " <>
        "'https://llm.internal/anthropic/v1/messages/count_tokens?beta=true' " <>
        ">#{private_file("token-count.json")} && " <>
        "test -s #{private_file("token-count.json")} && " <>
        "jq -e 'type == \"object\" and .input_tokens == 5' #{private_file("token-count.json")} >/dev/null"
    )
  end

  @spec codex_command(String.t()) :: String.t()
  defp codex_command(options \\ "") do
      "timeout --foreground -k 5 #{@native_timeout_seconds} codex #{options}exec --skip-git-repo-check --model fixture-model " <>
      "--output-last-message #{private_file("codex-last-message.txt")} " <>
      "'Reply with fixture codex reply'"
  end

  @spec claude_command() :: String.t()
  defp claude_command do
    "timeout --foreground -k 5 #{@native_timeout_seconds} claude -p --model fixture-model --output-format text " <>
      "'Reply with fixture claude reply' </dev/null"
  end

  @spec refusal(String.t(), String.t()) :: String.t()
  defp refusal(native_command, filename) do
    "umask 077; rm -f #{private_file("codex-last-message.txt")}; " <>
      "#{native_command} >#{private_file(filename)} 2>#{private_file(filename <> ".stderr")}; status=$?; " <>
      "test \"$status\" -ne 0 && test \"$status\" -ne 124 && test \"$status\" -ne 137 && " <>
      "! grep -Eq 'fixture (codex|claude) reply' #{private_file(filename)} && " <>
      "test ! -s #{private_file("codex-last-message.txt")}"
  end

  @spec private_file(String.t()) :: String.t()
  defp private_file(filename), do: "\"#{@private_directory}/#{filename}\""

  @spec native_deadline() :: pos_integer()
  defp native_deadline, do: (@native_timeout_seconds + 15) * 1000

  # @cc [owner:ghuntley,label:verification;security] coding-clis-private-terminal-output
  # Guest command output MUST remain in private guest files or be discarded.
  # PTY descriptor checks MUST precede that private output redirection.
  # Native-client timeouts MUST preserve the foreground PTY process group so
  # client terminal inspection cannot suspend a background process group.
  # Status matching MUST require a newline-delimited random marker, retain only
  # bounded matching state and report only fixed phase names, a closed failure
  # reason class and the bounded numeric shell status; failures MUST NOT expose
  # terminal bytes, native client output or exception details.
  @spec command(Terminal.t(), atom(), String.t(), pos_integer()) :: :ok
  defp command(socket, phase, shell, timeout \\ 30_000) do
    IO.puts(:stderr, "Coding CLI fixture stage: #{phase}")
    marker = "CODING_CLI_" <> Base.encode16(:crypto.strong_rand_bytes(12))

    :ok =
      Terminal.write(
        socket,
        "if test -t 0 && test -t 1; then (set -o pipefail; #{shell}) >/dev/null 2>&1; " <>
          "else false; fi; status=$?; printf '\\n#{marker}:%s\\n' \"$status\"\n"
      )

    case wait_status(socket, phase, marker, System.monotonic_time(:millisecond) + timeout, "") do
      0 -> :ok
      status -> raise Failure, phase: phase, reason: :command_failed, status: min(status, 255)
    end
  end

  @spec wait_status(Terminal.t(), atom(), String.t(), integer(), binary()) :: non_neg_integer()
  defp wait_status(socket, phase, marker, deadline, tail) do
    if System.monotonic_time(:millisecond) >= deadline,
      do: raise(Failure, phase: phase, reason: :command_timed_out)

    case Terminal.read(socket, 1000) do
      {:ok, bytes} ->
        body = :binary.replace(tail <> bytes, "\r", "", [:global])

        case Regex.run(~r/\n#{marker}:(\d+)\n/, body) do
          [_, status] ->
            String.to_integer(status)

          nil ->
            retained = min(byte_size(body), byte_size(marker) + 16)

            wait_status(
              socket,
              phase,
              marker,
              deadline,
              binary_part(body, byte_size(body) - retained, retained)
            )
        end

      {:error, :timeout} ->
        wait_status(socket, phase, marker, deadline, tail)

      _ ->
        raise Failure, phase: phase, reason: :terminal_unavailable
    end
  end
end

try do
  [mode, placement, username] = System.argv()
  :ok = FleetCodingCLIsGuest.run(mode, placement, username)
  IO.puts("Coding CLI guest assertion passed")
rescue
  # Only the fixed phase atom, closed reason class and bounded exit status are
  # reported; any other exception is classified without its message.
  failure in FleetCodingCLIsGuest.Failure ->
    status = if is_integer(failure.status), do: " status=#{failure.status}", else: ""

    IO.puts(
      :stderr,
      "Coding CLI guest assertion failed: phase=#{failure.phase} reason=#{failure.reason}" <>
        status <> "; terminal bytes withheld"
    )

    System.halt(1)

  _ ->
    IO.puts(:stderr, "Coding CLI guest assertion failed: phase=unknown reason=unexpected; terminal bytes withheld")
    System.halt(1)
end
