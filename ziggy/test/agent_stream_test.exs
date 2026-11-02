defmodule Ziggy.AgentStreamTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  property "reassembles completed output items across arbitrary chunk boundaries" do
    item = %{
      "type" => "function_call",
      "call_id" => "call-1",
      "name" => "read_file",
      "arguments" => ~s({"path":"/etc/hostname"})
    }

    bytes =
      "data: " <>
        Jason.encode!(%{
          "type" => "response.output_item.done",
          "output_index" => 0,
          "item" => item
        }) <>
        "\n\n" <>
        "data: " <>
        Jason.encode!(%{
          "type" => "response.completed",
          "response" => %{"status" => "completed", "output" => []}
        }) <> "\n\n"

    midpoint = draw("midpoint", integer(1..(byte_size(bytes) - 1)))

    <<first::binary-size(^midpoint), second::binary>> = bytes
    assert {:ok, partial} = Ziggy.AgentStream.feed(%Ziggy.AgentStream{}, first)
    assert {:ok, complete} = Ziggy.AgentStream.feed(partial, second)
    assert {:ok, %{"output" => [^item]}} = Ziggy.AgentStream.finish(complete)
  end

  test "missing completion and oversized frames cannot yield model output" do
    assert {:error, :invalid_response} = Ziggy.AgentStream.finish(%Ziggy.AgentStream{})

    assert {:error, :too_large} =
             Ziggy.AgentStream.feed(%Ziggy.AgentStream{}, String.duplicate("a", 2_097_153))
  end

  property "opaque compaction output and final-only responses survive arbitrary chunks" do
    response = %{
      "status" => "completed",
      "output" => [%{"type" => "compaction", "encrypted_content" => "synthetic-state"}],
      "usage" => %{"input_tokens" => 17, "output_tokens" => 6}
    }

    bytes = frame(%{"type" => "response.completed", "response" => response}, "\r\n")

    size = draw("size", integer(1..byte_size(bytes)))

    state = collect(bytes, size)
    assert {:ok, ^response} = Ziggy.AgentStream.finish(state)
  end

  property "SSE failures are terminal closed classes across arbitrary chunks" do
    pair =
      draw(
        "pair",
        member_of([
          {%{
             "type" => "error",
             "code" => "context_length_exceeded",
             "message" => "private"
           }, :context_length_exceeded},
          {%{
             "type" => "response.failed",
             "response" => %{
               "error" => %{"code" => "unsupported_compaction", "message" => "private"}
             }
           }, :unsupported_compaction},
          {%{
             "type" => "response.incomplete",
             "response" => %{"incomplete_details" => %{"reason" => "private"}}
           }, :incomplete},
          {%{"type" => "response.cancelled", "response" => %{}}, :cancelled},
          {%{"type" => "error", "message" => "private"}, :upstream_failed}
        ])
      )

    size = draw("size", integer(1..31))

    {event, expected} = pair
    # A later success cannot turn a known failed stream into executable output.
    bytes =
      frame(event) <>
        frame(%{
          "type" => "response.completed",
          "response" => %{"status" => "completed", "output" => []}
        })

    state = collect(bytes, size)
    assert {:error, ^expected} = Ziggy.AgentStream.finish(state)
    refute inspect(state) =~ "private"
  end

  test "missing item indices and conflicting terminal responses cannot dispatch tools" do
    item = %{"type" => "function_call", "name" => "write_file"}
    done = %{"type" => "response.output_item.done", "output_index" => 1, "item" => item}

    complete = %{
      "type" => "response.completed",
      "response" => %{"status" => "completed", "output" => []}
    }

    assert {:error, :invalid_response} =
             frame(done)
             |> Kernel.<>(frame(complete))
             |> collect(13)
             |> Ziggy.AgentStream.finish()

    assert {:error, :invalid_response} =
             frame(complete)
             |> Kernel.<>(frame(complete))
             |> collect(11)
             |> Ziggy.AgentStream.finish()
  end

  test "oversized final output and malformed output maps fail within the existing bound" do
    oversized = %{
      "type" => "response.completed",
      "response" => %{
        "status" => "completed",
        "output" => [%{"content" => String.duplicate("x", 1_048_576)}]
      }
    }

    assert {:error, :too_large} = Ziggy.AgentStream.feed(%Ziggy.AgentStream{}, frame(oversized))

    for output <- [List.duplicate(%{}, 257), ["not-an-item"], %{}] do
      state =
        collect(
          frame(%{
            "type" => "response.completed",
            "response" => %{"status" => "completed", "output" => output}
          }),
          71
        )

      assert {:error, :invalid_response} = Ziggy.AgentStream.finish(state)
    end
  end

  property "overload evidence survives chunking only with a recognized empty preamble" do
    size = draw("chunk size", integer(1..97))
    type = draw("terminal type", member_of(["error", "response.failed"]))

    event =
      if type == "error",
        do: %{"type" => type, "error" => %{"code" => "server_is_overloaded"}},
        else: %{
          "type" => type,
          "response" => %{
            "status" => "failed",
            "output" => [],
            "error" => %{"code" => "server_is_overloaded"}
          }
        }

    bytes =
      ": heartbeat\n\n" <>
        frame(%{
          "type" => "response.created",
          "response" => %{"status" => "in_progress", "output" => []}
        }) <> frame(event)

    state = collect(bytes, size)
    assert {:error, :server_is_overloaded} = Ziggy.AgentStream.finish(state)
    assert Ziggy.AgentStream.overload_before_output?(state)
  end

  property "output and uncertainty permanently disqualify overload replay across chunking" do
    size = draw("chunk size", integer(1..97))

    disqualifying =
      draw(
        "frame",
        member_of([
          frame(%{"type" => "response.output_text.delta", "delta" => "private"}),
          frame(%{"type" => "response.output_item.added", "item" => %{}}),
          frame(%{"type" => "response.output_item.done", "output_index" => 0, "item" => %{}}),
          frame(%{"type" => "response.unknown"}),
          frame(%{"type" => 123}),
          "data: malformed\n\n",
          "event: unrelated\ndata: {\"type\":\"response.created\",\"response\":{}}\n\n",
          frame(%{"type" => "response.created", "response" => %{"output" => [%{}]}}),
          frame(%{"type" => "response.created", "response" => %{"status" => "completed"}}),
          frame(%{
            "type" => "response.in_progress",
            "response" => %{"usage" => %{"output_tokens" => 1}}
          }),
          frame(%{
            "type" => "response.completed",
            "response" => %{"status" => "completed", "output" => []}
          })
        ])
      )

    overload = frame(%{"type" => "error", "code" => "server_is_overloaded"})

    for bytes <- [disqualifying <> overload, overload <> disqualifying] do
      state = collect(bytes, size)
      refute Ziggy.AgentStream.overload_before_output?(state)
      assert {:error, _} = Ziggy.AgentStream.finish(state)
    end
  end

  test "duplicate terminals, terminal output and trailing partial frames cannot authorize retry" do
    overload = frame(%{"type" => "error", "code" => "server_is_overloaded"})

    for bytes <- [
          overload <> overload,
          overload <> "data: partial",
          frame(%{
            "type" => "response.failed",
            "response" => %{"error" => %{"code" => "server_is_overloaded"}, "output" => [%{}]}
          }),
          frame(%{
            "type" => "response.failed",
            "response" => %{
              "status" => "completed",
              "error" => %{"code" => "server_is_overloaded"}
            }
          }),
          frame(%{
            "type" => "error",
            "code" => "server_is_overloaded",
            "response" => %{"output" => [%{}]}
          }),
          frame(%{
            "type" => "error",
            "error" => %{"code" => "server_is_overloaded", "output" => [%{}]}
          })
        ] do
      refute bytes |> collect(13) |> Ziggy.AgentStream.overload_before_output?()
    end
  end

  @spec frame(map(), binary()) :: binary()
  defp frame(event, separator \\ "\n"),
    do: "data:" <> Jason.encode!(event) <> separator <> separator

  @spec collect(binary(), pos_integer()) :: Ziggy.AgentStream.t()
  defp collect(bytes, size) do
    chunks = for <<chunk::binary-size(^size) <- bytes>>, do: chunk
    used = length(chunks) * size
    tail = binary_part(bytes, used, byte_size(bytes) - used)

    Enum.reduce(chunks ++ [tail], %Ziggy.AgentStream{}, fn chunk, state ->
      assert {:ok, next} = Ziggy.AgentStream.feed(state, chunk)
      next
    end)
  end
end
