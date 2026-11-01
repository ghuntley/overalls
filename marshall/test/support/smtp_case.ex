defmodule Marshall.Mailer.SMTPCase do
  @moduledoc """
  Marshall.Mailer's SMTP tests, shared by three test modules so each
  post-DATA timeout property (about 30 minutes of real ten-second timeouts)
  runs in its own Buck2 shard (ADR-0269 mix-test-sharded).

  A using module sets `@smtp_timeout_modes` (the properties it runs) and
  `@smtp_plain_tests` (whether it runs the other tests) before `use`.
  """

  defmacro __using__(_options) do
    quote unquote: false do
      use Marshall.DataCase, async: false
      import Hegel
      import Hegel.Gen
      import ExUnit.CaptureLog
      alias Marshall.Accounts.{AuthEmail, AuthEmails, User}
      alias Marshall.Compute.Ledger
      @fixtures Path.expand("../../fixtures/tls", __DIR__)

      setup do
        previous = Application.fetch_env!(:marshall, Marshall.Mailer)
        on_exit(fn -> Application.put_env(:marshall, Marshall.Mailer, previous) end)
        :ok
      end

      for {mode, name} <- [
            implicit: "generated implicit post-DATA timeout histories preserve retry identity",
            starttls: "generated starttls post-DATA timeout histories preserve retry identity"
          ],
          mode in @smtp_timeout_modes do
        # 100 cases retain up to two real ten-second uncertain attempts each.
        # Budget 26 seconds per case for their asserted deadlines, plus setup,
        # final/rejected delivery and cleanup headroom; no exploration is reduced.
        @tag timeout: 3_600_000, hegel_case_sandbox: true
        # @cc [owner:ghuntley,label:verification;recovery] smtp-uncertain-owner-history
        # Actual accepted-but-unacknowledged DATA MUST time out and close its client
        # connection, preserving pending ciphertext. All retries MUST retain decoded
        # payload and Message-ID, and terminal replay MUST open no SMTP connection.
        # Each case retains its actual ten-second post-DATA timeout attempts.
        property name, profile: :ci, test_cases: 100 do
          isolate_smtp_case()
          mode = unquote(mode)

          uncertain_attempts = draw("uncertain_attempts", integer(1..2))
          rejection? = draw("rejection?", boolean())
          terminal_replays = draw("terminal_replays", integer(1..3))
          {record, expected_token} = enqueue()
          ciphertext = record.encrypted_payload

          identities =
            Enum.map(1..uncertain_attempts, fn _attempt ->
              server = listener(mode, stall_after_data: true)
              configure(server, Atom.to_string(mode))
              started = System.monotonic_time(:millisecond)
              assert {:error, _} = deliver(record)
              elapsed = System.monotonic_time(:millisecond) - started
              assert elapsed >= 9_000 and elapsed < 13_000
              assert_receive {:smtp_connection, connection_owner}
              assert_receive {:smtp_auth, true}
              assert_receive {:smtp_message, bytes}
              assert_receive {:smtp_data_stalled, owner}
              assert owner == connection_owner
              assert_receive {:smtp_data_closed, ^owner}, 1000

              current =
                Ash.get!(AuthEmail, record.id,
                  actor: Marshall.Authorization.SystemActor.compute()
                )

              assert current.status == :pending
              # Compare only the boolean so failed assertions cannot print ciphertext.
              unchanged? = current.encrypted_payload == ciphertext
              assert unchanged?
              message_identity(bytes)
            end)

          identities =
            if rejection? do
              server = listener(mode, reply: "451 synthetic refusal\r\n")
              configure(server, Atom.to_string(mode))
              assert {:error, _} = deliver(record)
              assert_receive {:smtp_connection, _}
              assert_receive {:smtp_auth, true}
              assert_receive {:smtp_message, bytes}

              assert %{status: :pending} =
                       current =
                       Ash.get!(AuthEmail, record.id,
                         actor: Marshall.Authorization.SystemActor.compute()
                       )

              unchanged? = current.encrypted_payload == ciphertext
              assert unchanged?

              [message_identity(bytes) | identities]
            else
              identities
            end

          server = listener(mode)
          configure(server, Atom.to_string(mode))
          assert {:ok, %{status: :delivered, encrypted_payload: nil}} = deliver(record)
          assert_receive {:smtp_connection, _}
          assert_receive {:smtp_auth, true}
          assert_receive {:smtp_message, bytes}
          final_identity = message_identity(bytes)

          linked_token? =
            case Regex.run(~r{/magic_link/([^\s]+)}, decoded_text(bytes) || "") do
              [_, observed] -> Plug.Crypto.secure_compare(observed, expected_token)
              _ -> false
            end

          assert linked_token?
          assert Enum.all?(identities, &(&1 == final_identity))
          {message_id, _, _} = final_identity
          assert message_id == "<#{record.id}@overalls.invalid>"

          Enum.each(1..terminal_replays, fn _ ->
            assert {:ok, %{status: :delivered, encrypted_payload: nil}} = deliver(record)
          end)

          refute_receive {:smtp_connection, _}
          refute_receive {:smtp_auth, _}
          refute_receive {:smtp_message, _}
        end
      end

      # @cc [owner:ghuntley,label:verification;security] smtp-history-case-isolation
      # Every generated case and replay MUST own a fresh SQL sandbox and SMTP
      # listeners. Listener cleanup MUST precede fixture-message and mailer-setting
      # cleanup, then SQL rollback; real delivery and post-DATA deadlines MUST remain.
      @spec isolate_smtp_case() :: :ok
      @doc false
      def isolate_smtp_case do
        isolate_property_case()
        previous = Application.fetch_env!(:marshall, Marshall.Mailer)
        Hegel.on_cleanup(fn -> Application.put_env(:marshall, Marshall.Mailer, previous) end)
        Hegel.on_cleanup(&flush_smtp_fixture_messages/0)
      end

      @spec flush_smtp_fixture_messages() :: :ok
      @doc false
      def flush_smtp_fixture_messages do
        receive do
          {:smtp_connection, _} -> flush_smtp_fixture_messages()
          {:smtp_auth, _} -> flush_smtp_fixture_messages()
          {:smtp_message, _} -> flush_smtp_fixture_messages()
          {:smtp_data_stalled, _} -> flush_smtp_fixture_messages()
          {:smtp_data_closed, _} -> flush_smtp_fixture_messages()
          {:smtp_data_not_closed, _} -> flush_smtp_fixture_messages()
          :smtp_stalled -> flush_smtp_fixture_messages()
          :smtp_closed -> flush_smtp_fixture_messages()
        after
          0 -> :ok
        end
      end

      @spec deliver(AuthEmail.t()) :: {:ok, AuthEmail.t()} | {:error, term()}
      @doc false
      def deliver(record) do
        record
        |> Ash.Changeset.for_update(:deliver, %{},
          actor: Marshall.Authorization.SystemActor.compute()
        )
        |> Ash.update()
      end

      @spec message_identity(binary()) :: {binary(), binary(), binary()}
      @doc false
      def message_identity(bytes) do
        {"multipart", "alternative", headers, _, parts} = :mimemail.decode(bytes, [])

        {_, message_id} =
          Enum.find(headers, fn {name, _} -> String.downcase(name) == "message-id" end)

        {"text", "plain", _, _, text} = Enum.find(parts, &match?({"text", "plain", _, _, _}, &1))
        {"text", "html", _, _, html} = Enum.find(parts, &match?({"text", "html", _, _, _}, &1))
        true = is_binary(message_id) and is_binary(text) and is_binary(html)
        {message_id, :crypto.hash(:sha256, text), :crypto.hash(:sha256, html)}
      rescue
        _ -> flunk("Synthetic SMTP message has an unexpected MIME shape")
      end

      if @smtp_plain_tests do
        for mode <- [:implicit, :starttls] do
          test "magic-link job delivers through authenticated #{mode} TLS" do
            mode = unquote(mode)
            server = listener(mode)
            configure(server, Atom.to_string(mode))
            {record, expected_token} = enqueue()
            assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :mail)
            assert_receive {:smtp_auth, true}
            assert_receive {:smtp_message, bytes}
            assert String.contains?(bytes, "Your Overalls sign-in link")
            text = decoded_text(bytes)
            assert is_binary(text)
            [_, token] = Regex.run(~r{/magic_link/([^\s]+)}, text)
            same_token? = Plug.Crypto.secure_compare(token, expected_token)
            assert same_token?

            {:ok, user} =
              User
              |> Ash.Changeset.for_create(:sign_in_with_magic_link, %{token: token},
                context: %{private: %{ash_authentication?: true}}
              )
              |> Ash.create()

            assert {:ok, _, _} = Marshall.Accounts.Login.verify(user.__metadata__.token, user)

            reuse =
              User
              |> Ash.Changeset.for_create(:sign_in_with_magic_link, %{token: token},
                context: %{private: %{ash_authentication?: true}}
              )
              |> Ash.create()

            assert match?({:error, _}, reuse)

            assert [%{status: :delivered, encrypted_payload: nil}] =
                     Ledger.read!(AuthEmail, id: record.id)
          end
        end

        test "untrusted certificates and missing STARTTLS prevent credentials or mail from being sent" do
          server = listener(:implicit)
          configure(server, "implicit", ca: CAStore.file_path())
          {record, _} = enqueue()

          capture_log(fn ->
            assert %{success: 0, failure: 1} = Oban.drain_queue(queue: :mail)
          end)

          refute_receive {:smtp_auth, _}
          refute_receive {:smtp_message, _}
          assert [%{status: :pending}] = Ledger.read!(AuthEmail, id: record.id)

          server = listener(:plain)
          configure(server, "starttls")
          AshOban.run_trigger(record, :deliver)

          capture_log(fn ->
            assert %{success: 0, failure: 1} =
                     Oban.drain_queue(queue: :mail, with_scheduled: true)
          end)

          refute_receive {:smtp_auth, _}
          refute_receive {:smtp_message, _}
        end

        test "a provider rejection retries without storing token-bearing responses in jobs or logs" do
          {record, token} = enqueue()
          server = listener(:implicit, reply: "451 " <> token <> "\r\n")
          configure(server, "implicit")

          old_level = Logger.level()
          Logger.configure(level: :info)
          on_exit(fn -> Logger.configure(level: old_level) end)

          logs =
            capture_log(
              [metadata: [:event, :delivery_id, :delivery_status]],
              fn ->
                assert %{success: 0, failure: 1} = Oban.drain_queue(queue: :mail)
              end
            )

          assert [%{status: :pending}] = Ledger.read!(AuthEmail, id: record.id)

          %{rows: rows} =
            Ecto.Adapters.SQL.query!(Marshall.Repo, "SELECT args, errors FROM oban_jobs")

          secret_absent? = not String.contains?(inspect(rows) <> logs, token)
          assert secret_absent?
          assert logs =~ "Mail attempt finished"
          assert logs =~ "delivery_id=" <> record.id
          assert logs =~ "delivery_status=failed"
          server = listener(:implicit)
          configure(server, "implicit")

          retried =
            capture_log(
              [metadata: [:event, :delivery_id, :delivery_status]],
              fn ->
                assert %{success: 1, failure: 0} =
                         Oban.drain_queue(queue: :mail, with_scheduled: true)
              end
            )

          assert [%{status: :delivered, encrypted_payload: nil}] =
                   Ledger.read!(AuthEmail, id: record.id)

          assert retried =~ "Mail attempt finished"
          assert retried =~ "delivery_id=" <> record.id
          assert retried =~ "delivery_status=smtp_accepted"
          refute retried =~ token
        end

        test "a trusted certificate for the wrong hostname is still rejected" do
          directory = Path.join(System.tmp_dir!(), "overalls-smtp-#{Ash.UUID.generate()}")
          File.mkdir!(directory)
          on_exit(fn -> File.rm_rf!(directory) end)
          certificate = Path.join(directory, "wrong-host.pem")
          key = Path.join(directory, "wrong-host.key")

          {_, result} =
            System.cmd(
              "openssl",
              [
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-keyout",
                key,
                "-out",
                certificate,
                "-subj",
                "/CN=elsewhere.test",
                "-addext",
                "subjectAltName=DNS:elsewhere.test",
                "-days",
                "1"
              ],
              stderr_to_stdout: true
            )

          assert result == 0
          server = listener(:implicit, cert: certificate, key: key)
          configure(server, "implicit", ca: certificate)
          enqueue()

          capture_log(fn ->
            assert %{success: 0, failure: 1} = Oban.drain_queue(queue: :mail)
          end)

          refute_receive {:smtp_auth, _}
          refute_receive {:smtp_message, _}
        end

        @tag timeout: 20_000
        test "a stalled SMTP server cannot hold a job or connection beyond the total deadline" do
          server = listener(:implicit, stall: true)
          configure(server, "implicit")
          enqueue()
          started = System.monotonic_time(:millisecond)
          assert %{success: 0, failure: 1} = Oban.drain_queue(queue: :mail)
          elapsed = System.monotonic_time(:millisecond) - started
          assert elapsed >= 9_000 and elapsed < 13_000
          assert_receive :smtp_stalled
          assert_receive :smtp_closed, 1000
        end

        @spec listener(:implicit | :starttls | :plain, keyword()) :: pid()
      end

      @doc false
      def listener(mode, options \\ []) do
        opts =
          Keyword.merge(
            [
              mode: mode,
              owner: self(),
              cert: Path.join(@fixtures, "localhost.pem"),
              key: Path.join(@fixtures, "localhost.key")
            ],
            options
          )

        Overalls.HegelFixtures.start_fixture!({Marshall.SMTPFixture, opts}, id: make_ref())
      end

      @spec configure(pid(), String.t(), keyword()) :: :ok
      @doc false
      def configure(server, mode, options \\ []) do
        env = %{
          "MARSHALL_SMTP_HOST" => "localhost",
          "MARSHALL_SMTP_PORT" => to_string(Marshall.SMTPFixture.port(server)),
          "MARSHALL_SMTP_TLS" => mode,
          "MARSHALL_SMTP_USERNAME" => "test-user",
          "MARSHALL_SMTP_PASSWORD" => "test-password",
          "MARSHALL_MAIL_FROM" => "noreply@example.test",
          "MARSHALL_SMTP_CA_CERTFILE" => Keyword.get(options, :ca, Path.join(@fixtures, "ca.pem"))
        }

        {:ok, config, _} = Marshall.Mailer.Config.from_env(env)
        Application.put_env(:marshall, Marshall.Mailer, config)
      end

      @spec enqueue() :: {AuthEmail.t(), String.t()}
      @doc false
      def enqueue do
        existing = MapSet.new(Ledger.read!(AuthEmail), & &1.id)
        email = "smtp-#{binary_part(Ash.UUID.generate(), 0, 16)}@example.test"
        strategy = AshAuthentication.Info.strategy!(User, :magic_link)

        {:ok, token} =
          AshAuthentication.Strategy.MagicLink.request_token_for_identity(strategy, email)

        :ok = AuthEmails.enqueue(email, token)
        [record] = Enum.reject(Ledger.read!(AuthEmail), &MapSet.member?(existing, &1.id))
        {record, token}
      end

      @doc false
      def plain_text({"text", "plain", _, _, body}), do: body
      def plain_text({"multipart", _, _, _, parts}), do: Enum.find_value(parts, &plain_text/1)
      def plain_text(_), do: nil

      @doc false
      def decoded_text(bytes) do
        bytes |> :mimemail.decode([]) |> plain_text()
      rescue
        _ -> nil
      end
    end
  end
end
