defmodule Susan.TokenBucket do
  @moduledoc """
  Pure token-bucket arithmetic in integer milli-tokens.

  A bucket holds at most `burst` tokens and refills `per_hour` tokens per
  hour. Time is integer milliseconds supplied by the caller, so the model is
  deterministic and property-testable; a clock that goes backwards never adds
  tokens.
  """

  @enforce_keys [:level, :at, :limited]
  defstruct [:level, :at, :limited, carry: 0]

  @scale 1000
  @hour_ms 3_600_000

  @type limit :: %{burst: pos_integer(), per_hour: pos_integer()}
  # `carry` is the refill earned below one milli-token, scaled by @hour_ms
  # (so always below @hour_ms): elapsed time is counted exactly once.
  @type t :: %__MODULE__{
          level: non_neg_integer(),
          at: integer(),
          limited: boolean(),
          carry: non_neg_integer()
        }
  @type result ::
          {:ok, t()}
          | {:error, retry_after_seconds :: pos_integer(), first_refusal :: boolean(), t()}

  @spec new(limit(), integer()) :: t()
  def new(%{burst: burst}, now_ms),
    do: %__MODULE__{level: burst * @scale, at: now_ms, limited: false}

  # @cc [owner:ghuntley,label:capacity;security] susan-token-bucket-bounds
  # A bucket MUST never exceed its burst, never go negative, never refill when
  # time does not advance, and MUST admit at most burst + elapsed*rate tokens
  # over any interval. A refusal MUST report a positive Retry-After that is
  # sufficient for one token to refill.
  @spec take(t() | nil, limit(), integer()) :: result()
  def take(nil, limit, now_ms), do: take(new(limit, now_ms), limit, now_ms)

  def take(%__MODULE__{} = bucket, %{burst: burst, per_hour: per_hour}, now_ms) do
    elapsed = max(now_ms - bucket.at, 0)
    # Refill in exact rational time: the part below one milli-token carries
    # into the next take, so no elapsed time is lost or counted twice.
    earned = elapsed * per_hour * @scale + bucket.carry
    level = min(bucket.level + div(earned, @hour_ms), burst * @scale)
    carry = if level == burst * @scale, do: 0, else: rem(earned, @hour_ms)
    at = max(now_ms, bucket.at)

    if level >= @scale do
      {:ok, %__MODULE__{level: level - @scale, at: at, limited: false, carry: carry}}
    else
      missing = @scale - level
      rate = per_hour * @scale
      retry_ms = div(missing * @hour_ms - carry + rate - 1, rate)
      retry = max(div(retry_ms + 999, 1000), 1)

      {:error, retry, not bucket.limited,
       %__MODULE__{level: level, at: at, limited: true, carry: carry}}
    end
  end

  @doc "Whether the bucket has refilled to its burst, so it equals a fresh bucket."
  @spec full?(t(), limit(), integer()) :: boolean()
  def full?(%__MODULE__{} = bucket, %{burst: burst, per_hour: per_hour}, now_ms) do
    elapsed = max(now_ms - bucket.at, 0)
    bucket.level + div(elapsed * per_hour * @scale + bucket.carry, @hour_ms) >= burst * @scale
  end
end
