defmodule Ziggy.CredentialTest do
  use ExUnit.Case, async: true

  test "runtime keys must be private, bounded, regular files" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ziggy-key-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    File.mkdir!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "key")
    File.write!(path, "synthetic-key\n")
    File.chmod!(path, 0o600)
    assert {:ok, "synthetic-key"} = Ziggy.Credential.read(path)
    File.chmod!(path, 0o644)
    assert {:error, :invalid_credential} = Ziggy.Credential.read(path)
    File.chmod!(path, 0o600)
    File.write!(path, "synthetic\ninjection")
    assert {:error, :invalid_credential} = Ziggy.Credential.read(path)
    File.ln_s!(path, path <> "-link")
    assert {:error, :invalid_credential} = Ziggy.Credential.read(path <> "-link")
    assert {:error, :invalid_credential} = Ziggy.Credential.read("/nix/store/synthetic/key")
  end

  test "provider header construction discards guest authority" do
    headers =
      Ziggy.Upstream.headers(:anthropic, "synthetic-key", [
        {"authorization", "guest"},
        {"host", "evil.example"},
        {"x-api-key", "guest"},
        {"anthropic-beta", "synthetic-beta"},
        {"x-forwarded-for", "127.0.0.1"}
      ])

    assert {"x-api-key", "synthetic-key"} in headers
    assert {"anthropic-beta", "synthetic-beta"} in headers
    refute List.keymember?(headers, "authorization", 0)
    refute List.keymember?(headers, "host", 0)
    refute List.keymember?(headers, "x-forwarded-for", 0)
  end
end
