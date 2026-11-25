defmodule Lilly.VM.APITest do
  use ExUnit.Case, async: true
  alias Lilly.VM.API
  @id "9af58c48-2846-4c31-985a-a1d7efedb71a"

  defp serve(chunks, fun) do
    path =
      Path.join(System.tmp_dir!(), "lilly-api-" <> Base.encode16(:crypto.strong_rand_bytes(8)))

    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {:local, path}])

    start_supervised!(
      {Task,
       fn ->
         {:ok, socket} = :gen_tcp.accept(listener, 3000)
         {:ok, _} = :gen_tcp.recv(socket, 0, 3000)
         Enum.each(chunks, &:gen_tcp.send(socket, &1))
         :gen_tcp.close(socket)
       end}
    )

    try do
      fun.(path)
    after
      :gen_tcp.close(listener)
      stop_supervised(Task)
      File.rm(path)
    end
  end

  test "requires a running matching instance and supported VMM version" do
    for {id, state, version, expected} <- [
          {@id, "Running", "1.17.0", true},
          {@id, "Not started", "1.17.0", false},
          {"another-vm", "Running", "1.17.0", false},
          {@id, "Running", "unknown", false}
        ] do
      body = JSON.encode!(%{"id" => id, "state" => state, "vmm_version" => version})
      head = "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\n\r\n"
      serve([head, body], fn path -> assert API.running?(path, @id) == expected end)
    end
  end

  test "oversized, ambiguous, truncated and invalid responses never establish readiness" do
    for response <- [
          "garbage",
          "HTTP/1.1 200 OK\r\nContent-Length: 999999\r\n\r\n",
          "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
          "HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\n{}",
          String.duplicate("a", 16385)
        ] do
      serve([response], fn path -> refute API.running?(path, @id) end)
    end
  end

  test "shutdown accepts only the API's successful action response" do
    serve(["HTTP/1.1 204 No Content\r\n\r\n"], fn path ->
      assert API.shutdown(path) == :ok
    end)

    serve(["HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n"], fn path ->
      assert API.shutdown(path) == :ok
    end)

    serve(["HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"], fn path ->
      assert {:error, :vmm_api_unavailable} = API.shutdown(path)
    end)
  end
end
