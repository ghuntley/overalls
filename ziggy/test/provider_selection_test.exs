defmodule Ziggy.ProviderSelectionTest do
  use ExUnit.Case, async: true
  import Plug.Conn

  @host "11111111-1111-4111-8111-111111111111"

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ziggy-config-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    File.mkdir!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    for {name, value} <- [
          {"token", String.duplicate("x", 80)},
          {"openai", "synthetic-openai"},
          {"anthropic", "synthetic-anthropic"},
          {"ca", "synthetic-ca"}
        ] do
      File.write!(Path.join(dir, name), value)
      File.chmod!(Path.join(dir, name), 0o600)
    end

    config = %{
      "version" => 1,
      "host_id" => @host,
      "control_plane" => "https://control.example.test",
      "ca_file" => Path.join(dir, "ca"),
      "credential_file" => Path.join(dir, "token"),
      "openai_key_file" => Path.join(dir, "openai"),
      "anthropic_key_file" => Path.join(dir, "anthropic"),
      "socket" => Path.join(dir, "socket"),
      "spool" => Path.join(dir, "spool"),
      "max_requests" => 10
    }

    %{dir: dir, config: config}
  end

  test "old configurations retain both providers; explicit selection does not load disabled keys",
       %{dir: dir, config: config} do
    assert {:ok, %{credentials: %{openai: _, anthropic: _}}} = load(dir, config)
    File.rm!(config["anthropic_key_file"])

    assert {:ok, %{credentials: credentials}} =
             load(dir, Map.put(config, "enabled_providers", ["openai"]))

    assert credentials == %{openai: "synthetic-openai"}
    assert {:error, :invalid_configuration} = load(dir, config)
  end

  test "empty, duplicated, unknown and malformed selections fail closed", %{
    dir: dir,
    config: config
  } do
    for providers <- [[], ["openai", "openai"], ["unknown"], "openai", nil] do
      assert {:error, :invalid_configuration} =
               load(dir, Map.put(config, "enabled_providers", providers))
    end
  end

  test "IPv6 control origins are rejected", %{dir: dir, config: config} do
    for origin <- ["https://[::1]", "https://[2001:db8::1]", "https://[::ffff:127.0.0.1]"] do
      assert {:error, :invalid_configuration} =
               load(dir, Map.put(config, "control_plane", origin))
    end
  end

  test "Underclass origin is a closed configuration choice", %{dir: dir, config: config} do
    assert {:ok, %{openai_origin: "http://127.0.0.1:8080"}} =
             load(dir, Map.put(config, "openai_origin", "http://127.0.0.1:8080"))

    for origin <- ["http://127.0.0.2:8080", "http://evil.test", "http://127.0.0.1:8081"] do
      assert {:error, :invalid_configuration} =
               load(dir, Map.put(config, "openai_origin", origin))
    end
  end

  test "agent model polling requires an explicit boolean switch", %{dir: dir, config: config} do
    assert {:ok, %{agent_enabled: false}} = load(dir, config)
    assert {:ok, %{agent_enabled: true}} = load(dir, Map.put(config, "agent_enabled", true))

    for value <- [nil, "true", 1] do
      assert {:error, :invalid_configuration} =
               load(dir, Map.put(config, "agent_enabled", value))
    end
  end

  test "executor bootstrap is optional and cannot use mutable deployment paths", %{
    dir: dir,
    config: config
  } do
    assert {:ok, %{bootstrap_release: nil}} = load(dir, config)

    for root <- ["/tmp/release", "/nix/store/../release", "relative", 1, %{}] do
      assert {:error, :invalid_configuration} =
               load(dir, Map.put(config, "executor_bootstrap_release", root))
    end
  end

  test "GitHub tools are optional and deployment paths stay immutable", %{
    dir: dir,
    config: config
  } do
    assert {:ok, %{github_tools: nil}} = load(dir, config)
    assert {:ok, %{github_tools: nil}} = load(dir, Map.put(config, "github_tools_release", nil))

    for root <- ["/tmp/release", "/nix/store/../release", "relative", 1, %{}] do
      assert {:error, :invalid_configuration} =
               load(dir, Map.put(config, "github_tools_release", root))
    end
  end

  test "guest update source is a fixed Nix release path", %{dir: dir, config: config} do
    assert {:ok, %{lyra_release: nil}} = load(dir, config)

    for value <- ["/tmp/release", "/nix/store/test-release", "https://example.test", 1] do
      assert {:error, :invalid_configuration} =
               load(dir, Map.put(config, "lyra_release", value))
    end
  end

  test "disabled provider rejects before accessing authority or spool" do
    binding = %{
      "host_id" => @host,
      "vm_id" => @host,
      "placement_id" => @host,
      "execution_epoch" => 1
    }

    for path <- [
          "/v1/messages",
          "/v1/messages/count_tokens",
          "/anthropic/v1/messages",
          "/anthropic/v1/messages/count_tokens"
        ],
        query <- ["", "?beta=true"] do
      conn =
        Plug.Test.conn(
          :post,
          "http://llm.internal" <> path <> query,
          ~s({"model":"synthetic-model","messages":[]})
        )
        |> put_req_header("content-type", "application/json")
        |> put_req_header(
          "x-overalls-binding",
          Base.url_encode64(Jason.encode!(binding), padding: false)
        )

      # Deliberately omit authority/spool configuration: reaching either would fail.
      response = Ziggy.HTTP.call(conn, %{host_id: @host, credentials: %{openai: "synthetic"}})
      assert response.status == 503
      assert Jason.decode!(response.resp_body) == %{"error" => "provider_unavailable"}
    end
  end

  test "guest executor cannot supply its own VM binding" do
    binding = %{
      "host_id" => @host,
      "vm_id" => @host,
      "placement_id" => @host,
      "execution_epoch" => 1
    }

    conn =
      Plug.Test.conn(
        :post,
        "http://llm.internal/agent/v1/register",
        Jason.encode!(%{"binding" => binding})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header(
        "x-overalls-binding",
        Base.url_encode64(Jason.encode!(binding), padding: false)
      )

    response = Ziggy.HTTP.call(conn, %{host_id: @host, control: nil})
    assert response.status == 400
    assert Jason.decode!(response.resp_body) == %{"error" => "invalid_request"}
  end

  test "SSH authority rejects guest binding injection and inference routes" do
    binding = %{
      "host_id" => @host,
      "vm_id" => @host,
      "placement_id" => @host,
      "execution_epoch" => 1
    }

    header = Base.url_encode64(Jason.encode!(binding), padding: false)

    injected =
      Plug.Test.conn(
        :post,
        "http://ssh.integration.internal/ssh/v1/authorize",
        Jason.encode!(%{"binding" => binding, "username" => "alice", "public_key" => "key"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-overalls-binding", header)

    response = Ziggy.HTTP.call(injected, %{host_id: @host, control: nil})
    assert response.status == 400
    assert Jason.decode!(response.resp_body) == %{"error" => "invalid_request"}

    inference =
      Plug.Test.conn(:get, "http://ssh.integration.internal/v1/models")
      |> put_req_header("x-overalls-binding", header)

    assert Ziggy.HTTP.call(inference, %{host_id: @host, control: nil}).status == 404

    unknown =
      Plug.Test.conn(:get, "http://ssh.internal/ssh/v1/roster")
      |> put_req_header("x-overalls-binding", header)

    assert Ziggy.HTTP.call(unknown, %{host_id: @host, control: nil}).status == 403

    # The ordinary four-field binding is not a boot proof for the roster or
    # host-certificate routes.
    for {method, url} <- [
          {:get, "http://ssh.integration.internal/ssh/v1/roster"},
          {:post, "http://ssh.integration.internal/ssh/v1/host-certificate"}
        ] do
      conn = Plug.Test.conn(method, url, "{}") |> put_req_header("x-overalls-binding", header)
      assert Ziggy.HTTP.call(conn, %{host_id: @host, control: nil}).status == 403
    end
  end

  test "bootstrap binding cannot enter authorization, login, inference or agent routes" do
    binding = %{
      "host_id" => @host,
      "vm_id" => @host,
      "placement_id" => @host,
      "execution_epoch" => 1,
      "generation" => 1,
      "operation_id" => @host
    }

    header = Base.url_encode64(Jason.encode!(binding), padding: false)

    for {method, url} <- [
          {:post, "http://ssh.integration.internal/ssh/v1/authorize"},
          {:post, "http://ssh.integration.internal/ssh/v1/login"},
          {:get, "http://ssh.integration.internal/ssh/v1/authorized-keys"},
          {:get, "http://ssh.integration.internal/ssh/v1/roster?extra=1"},
          {:get, "http://ssh.integration.internal/ssh/v1/host-certificate"},
          {:post, "http://ssh.integration.internal/ssh/v1/host-certificate?extra=1"},
          {:post, "http://llm.internal/ssh/v1/host-certificate"},
          {:post, "http://llm.internal/anthropic/v1/messages"},
          {:post, "http://llm.internal/agent/v1/register"}
        ] do
      conn = Plug.Test.conn(method, url, "{}") |> put_req_header("x-overalls-binding", header)
      response = Ziggy.HTTP.call(conn, %{host_id: @host, control: nil})
      assert response.status == 403
    end
  end

  defp load(dir, config) do
    path = Path.join(dir, "config.json")
    File.write!(path, Jason.encode!(config))
    Ziggy.Config.load(path)
  end
end
