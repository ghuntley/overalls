defmodule Susan.TokenBucketPropertyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Susan.TokenBucket

  @hour 3_600_000

  test "the documented per-key limit admits a burst of ten then refuses" do
    limit = %{burst: 10, per_hour: 60}

    {bucket, admitted} =
      Enum.reduce(1..10, {nil, 0}, fn _, {bucket, count} ->
        {:ok, bucket} = TokenBucket.take(bucket, limit, 0)
        {bucket, count + 1}
      end)

    assert admitted == 10
    assert {:error, 60, true, bucket} = TokenBucket.take(bucket, limit, 0)
    assert {:error, _, false, bucket} = TokenBucket.take(bucket, limit, 1_000)
    assert {:ok, _} = TokenBucket.take(bucket, limit, 60_000)
  end

  # A shrunk counterexample to the earlier oracle, which measured the refill
  # window from time zero rather than from the first request: the first take
  # at -391 ms starts a full bucket there, and the 780 ms that follow refill
  # two tokens at 9231 per hour.
  test "a first request before time zero refills from the first request" do
    assert admissions_within_bound(1, 9231, [-391, 390, 390]) == 3
  end

  @tag :hegel
  test "admissions never exceed burst plus refill and refusals name a sufficient wait" do
    Hegel.check(
      fn ->
        burst = draw("burst", integer(1, 50))
        rate = draw("rate", integer(1, 10_000))
        steps = draw("steps", list_of(integer(-5_000, 120_000), max_length: 80))
        admissions_within_bound(burst, rate, steps)
      end,
      test_cases: 300
    )
  end

  # Takes one request at each running sum of steps and checks the contract
  # susan-token-bucket-bounds: every refusal names a sufficient wait, and over
  # the interval from the first request to the latest time reached the bucket
  # admits at most burst + floor(span * rate / hour). A clock that goes
  # backwards adds nothing, so the span ends at the latest time, not the last.
  @spec admissions_within_bound(pos_integer(), pos_integer(), [integer()]) :: non_neg_integer()
  defp admissions_within_bound(burst, rate, steps) do
    limit = %{burst: burst, per_hour: rate}
    times = steps |> Enum.scan(&(&1 + &2))

    {_, admitted} =
      Enum.reduce(times, {nil, 0}, fn now, {bucket, admitted} ->
        case TokenBucket.take(bucket, limit, now) do
          {:ok, next} ->
            assert next.level >= 0 and next.level <= burst * 1000
            {next, admitted + 1}

          {:error, retry, _first, next} ->
            assert retry > 0
            assert next.level < 1000
            # Waiting the advertised Retry-After always admits one request.
            assert {:ok, _} = TokenBucket.take(next, limit, max(now, next.at) + retry * 1000)
            {next, admitted}
        end
      end)

    case times do
      [] ->
        assert admitted == 0

      [first | _] ->
        span = Enum.max(times) - first
        assert admitted <= burst + div(span * rate, @hour)
    end

    admitted
  end

  @tag :hegel
  test "time that does not advance never refills" do
    Hegel.check(
      fn ->
        burst = draw("burst", integer(1, 20))
        limit = %{burst: burst, per_hour: draw("rate", integer(1, 100_000))}
        at = draw("at", integer(0, 1_000_000))

        results =
          Enum.map_reduce(1..(burst + 5), nil, fn _, b ->
            case TokenBucket.take(b, limit, at) do
              {:ok, n} -> {:ok, n}
              {:error, _, _, n} -> {:error, n}
            end
          end)
          |> elem(0)

        assert Enum.count(results, &(&1 == :ok)) == burst
      end,
      test_cases: 200
    )
  end
end
