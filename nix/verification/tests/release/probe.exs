# @cc [owner:ghuntley,label:verification] release-payload-validation
# This check MUST execute in the packaged OTP release and verify shipped protocol,
# independent consumers and Marshall's actual Cedar NIF and generated assets.
application = System.fetch_env!("OVERALLS_RELEASE_APPLICATION")
root = System.fetch_env!("OVERALLS_RELEASE_ROOT")
expected_elixir = System.fetch_env!("OVERALLS_RELEASE_ELIXIR")

if System.version() != expected_elixir, do: raise("release Elixir version mismatch")
if :erlang.system_info(:otp_release) != ~c"29", do: raise("release OTP version mismatch")
if to_string(:erlang.system_info(:version)) != System.fetch_env!("OVERALLS_RELEASE_ERTS"),
  do: raise("release ERTS differs from the pinned OTP runtime")
if not Code.ensure_loaded?(OverallsProtocol), do: raise("shared protocol missing from release")

metadata = root |> Path.join("overalls-release.json") |> File.read!() |> JSON.decode!()
if metadata["build"] != "nix-source", do: raise("source build metadata missing")
if metadata["application"] != application, do: raise("incorrect release application")
if metadata["elixir"] != expected_elixir, do: raise("incorrect runtime metadata")
if metadata["otp"] != System.fetch_env!("OVERALLS_RELEASE_OTP"),
  do: raise("incorrect OTP metadata")
if File.exists?(Path.join(root, "releases/COOKIE")), do: raise("release cookie was packaged")

case application do
  "ziggy" ->
    for module <- [Marshall.Application, Lilly.Application, Audi.Application, Ash, Oban, Ecto.Repo] do
      if Code.ensure_loaded?(module), do: raise("domain or provisioner runtime included in Ziggy")
    end
    if Map.has_key?(metadata, "host_tools") or File.exists?(Path.join(root, "host-tools")),
      do: raise("privileged host tools included in Ziggy release")
    for module <- [Ziggy.Application, Ziggy.Config, Ziggy.HTTP, Ziggy.Lease,
      Ziggy.Spool, Ziggy.Reporter, Ziggy.Catalog, Ziggy.Upstream, Ziggy.Privacy, LLMDB] do
      if not Code.ensure_loaded?(module), do: raise("Ziggy release module missing")
    end
    {:error, _} = apply(Ziggy.Route, :resolve, ["POST", "/v1/audio/speech", "", "{}"])
  "brady" ->
    for module <- [Marshall.Application, Lilly.Application, Audi.Application, Porsche.Application, Ash, Oban, Ecto.Repo] do
      if Code.ensure_loaded?(module), do: raise("domain or provisioner runtime included in Brady")
    end
    for module <- [Brady.Application, Brady.Config, Brady.Proxy, Brady.Listener,
      Brady.TLS.Certificates, Brady.Cache.Store, Brady.Cache.Recovery, Brady.Metrics] do
      if not Code.ensure_loaded?(module), do: raise("Brady release module missing")
    end
    {:error, :invalid_configuration} = apply(Brady.Config, :load, ["/missing-brady-runtime-configuration"])
    if Map.has_key?(metadata, "host_tools") or File.exists?(Path.join(root, "host-tools")),
      do: raise("privileged host tools included in Brady release")

  "galileo" ->
    for module <- [Marshall.Application, Lilly.Application, Audi.Application, Enrico.Application,
      Ash, Oban, Ecto.Repo] do
      if Code.ensure_loaded?(module), do: raise("another service or domain runtime included in Galileo")
    end
    if Map.has_key?(metadata, "host_tools") or File.exists?(Path.join(root, "host-tools")),
      do: raise("privileged host tools included in Galileo release")
    for module <- [Galileo.Application, Galileo.Config, Galileo.Credential,
      Galileo.Control, Galileo.HTTP, Galileo.Upstream, Galileo.Strip, Galileo.Privacy] do
      if not Code.ensure_loaded?(module), do: raise("Galileo release module missing")
    end
    if not File.regular?(Path.join(root, "bin/galileo")), do: raise("Galileo release executable missing")
    {:error, :invalid_configuration} = apply(Galileo.Config, :load, ["/missing-galileo-runtime-configuration"])
    {:ok, []} = apply(Galileo.Application, :children, [nil])
    "/users" = apply(Galileo.Strip, :apply, ["/api/v3", "/api/v3/users"])
    "/api/v3x/users" = apply(Galileo.Strip, :apply, ["/api/v3", "/api/v3x/users"])

  "susan" ->
    for module <- [Marshall.Application, Lilly.Application, Audi.Application, Porsche.Application,
      Galileo.Application] do
      if Code.ensure_loaded?(module), do: raise("another Overalls service included in Susan")
    end
    if Map.has_key?(metadata, "host_tools") or File.exists?(Path.join(root, "host-tools")),
      do: raise("privileged host tools included in Susan release")
    for module <- [Susan.Application, Susan.Config, Susan.HTTP, Susan.Poke, Susan.Poke.Machine,
      Susan.PushKey, Susan.Audit.Log, Susan.Release, Susan.Operator, Susan.Privacy, Ash, Oban] do
      if not Code.ensure_loaded?(module), do: raise("Susan release module missing")
    end
    if not File.regular?(Path.join(root, "bin/susan")), do: raise("Susan release executable missing")
    migrations = Path.wildcard(Path.join(root, "lib/susan-*/priv/repo/migrations/*.exs"))
    if length(migrations) < 4, do: raise("Susan migrations missing from release")
    {:error, :invalid_runtime_configuration} =
      apply(Susan.Config, :load, ["/missing-susan-runtime-configuration", "/missing-credentials"])
    for module <- [Covenant, Hegel, Dialyxir] do
      if Code.ensure_loaded?(module), do: raise("development dependency included in Susan release")
    end

  "enrico" ->
    for module <- [Marshall.Application, Lilly.Application, Audi.Application, Galileo.Application,
      Ash, Oban, Ecto.Repo] do
      if Code.ensure_loaded?(module), do: raise("another service or domain runtime included in Enrico")
    end
    if Map.has_key?(metadata, "host_tools") or File.exists?(Path.join(root, "host-tools")),
      do: raise("privileged host tools included in Enrico release")
    for module <- [Enrico.Application, Enrico.Config, Enrico.Git, Enrico.HTTP,
      Enrico.Health, Enrico.Manager, Enrico.RefreshSupervisor, Enrico.Privacy] do
      if not Code.ensure_loaded?(module), do: raise("Enrico release module missing")
    end
    if not File.regular?(Path.join(root, "bin/enrico")), do: raise("Enrico release executable missing")
    {:error, :invalid_configuration} = apply(Enrico.Config, :load, ["/missing-enrico-runtime-configuration"])
    false = apply(Enrico.Git, :valid_source?, ["../escape", "repo"])
    true = apply(Enrico.Git, :valid_source?, ["public-owner", "public-repo"])

  "porsche" ->
    for module <- [Marshall.Application, Lilly.Application, Audi.Application, Ash, Oban, Ecto.Repo] do
      if Code.ensure_loaded?(module), do: raise("domain or provisioner runtime included in Porsche")
    end
    if Map.has_key?(metadata, "host_tools") or File.exists?(Path.join(root, "host-tools")),
      do: raise("privileged host tools included in Porsche release")
    for module <- [Porsche.Application, Porsche.Config, Porsche.Client, Porsche.Runner,
      Porsche.Listener, Porsche.Connection, Porsche.SSH.Channel, Porsche.Privacy, Porsche.Observability] do
      if not Code.ensure_loaded?(module), do: raise("Porsche release module missing")
    end
    {:ok, _} = apply(OverallsProtocol.SSHCommand, :parse, ["help --json"])
    {:ok, []} = apply(Porsche.Application, :listener_children, [nil])
    {:error, :invalid_runtime_configuration} =
      apply(Porsche.Config, :load, ["/missing-porsche-runtime-configuration"])

  "audi" ->
    if Code.ensure_loaded?(Marshall.Application) or Code.ensure_loaded?(Lilly.Application),
      do: raise("control plane or provisioner included in Audi release")
    if Map.has_key?(metadata, "host_tools") or File.exists?(Path.join(root, "host-tools")),
      do: raise("privileged host tools included in Audi release")
    for module <- [Audi.Application, Audi.DNS.Server, Audi.DNS.Authority, Audi.OTPReports,
      Audi.Control.Client, Audi.Authority.StreamGuard, Audi.SSH.Listener, Audi.SSH.Channel] do
      if not Code.ensure_loaded?(module), do: raise("Audi release module missing")
    end
    {:error, :malformed} = apply(Audi.DNS.Wire, :decode, [<<0>>])

  "peach" ->
    for module <- [Marshall.Application, Lilly.Application, Audi.Application, Porsche.Application,
      Galileo.Application, Ash, Oban, Ecto.Repo] do
      if Code.ensure_loaded?(module), do: raise("another service or domain runtime included in Peach")
    end
    if Map.has_key?(metadata, "host_tools") or File.exists?(Path.join(root, "host-tools")),
      do: raise("privileged host tools included in Peach release")
    for module <- [Peach.Application, Peach.Config, Peach.Control, Peach.HTTP, Peach.Privacy] do
      if not Code.ensure_loaded?(module), do: raise("Peach release module missing")
    end
    if not File.regular?(Path.join(root, "bin/peach")), do: raise("Peach release executable missing")
    {:error, :invalid_configuration} = apply(Peach.Config, :load, ["/missing-peach-runtime-configuration"])
    {:ok, []} = apply(Peach.Application, :children, [nil])

  "lilly" ->
    if Code.ensure_loaded?(Marshall.Application), do: raise("Marshall included in Lilly release")

    for tool <- ["firecracker", "jailer", "unshare"] do
      path = Map.fetch!(metadata, tool)
      if not File.regular?(path), do: raise("missing host runtime executable")
    end

  "marshall" ->
    if Code.ensure_loaded?(Lilly.Application), do: raise("Lilly included in Marshall release")
    operator_dir = Path.join(System.fetch_env!("TMPDIR"), "gateway-operator")
    File.mkdir!(operator_dir)
    File.chmod!(operator_dir, 0o700)
    token_path = Path.join(operator_dir, "gateway.token")
    {:ok, %{prepared: true}} = Marshall.Operations.CLI.run(["gateway-prepare", token_path])
    {:ok, token} = Marshall.Operations.PrivateFiles.read(token_path)
    {:ok, _digest} = Marshall.SSH.Token.digest(token, :gateway)
    {:error, :output_exists} = Marshall.Operations.CLI.run(["gateway-prepare", token_path])
    File.rm!(token_path)
    File.rmdir!(operator_dir)
    cedar = Path.join(:code.priv_dir(:marshall), "cedar")
    {:ok, _engine} =
      Marshall.Authorization.Native.compile(
        File.read!(Path.join(cedar, "compute.cedar")),
        File.read!(Path.join(cedar, "schema.cedarschema"))
      )

    priv = :code.priv_dir(:marshall) |> List.to_string()
    static = Path.join(priv, "static")
    manifest = static |> Path.join("cache_manifest.json") |> File.read!() |> JSON.decode!()

    for asset <- ["assets/js/app.js", "assets/css/app.css"] do
      digested = Map.fetch!(manifest["latest"], asset)
      if File.stat!(Path.join(static, digested)).size == 0, do: raise("empty release asset")
    end

    if File.exists?(Path.join(static, "CONTRACTS")), do: raise("public contract artifact")

    # Public documentation must work from the release without starting services
    # or requiring the Markdown renderer at runtime.
    {:ok, index} = Marshall.Documentation.page("index")
    if index.markdown != File.read!(Path.join(priv, "docs/index.md")),
      do: raise("public documentation differs from its packaged source")
    if not String.contains?(index.html, "<h1>"), do: raise("rendered documentation missing")
    {:ok, reference} = Marshall.Documentation.page("commands")
    for command <- OverallsProtocol.SSHCommand.catalog() do
      if not String.contains?(reference.markdown, "`#{command.usage}`"),
        do: raise("release command documentation is incomplete")
    end
    :error = Marshall.Documentation.page("../runtime.exs")
    if not String.contains?(Marshall.Documentation.llms(), "/docs/commands.md"),
      do: raise("LLM documentation index missing")
end

IO.puts("#{application}: source release payload verified")
