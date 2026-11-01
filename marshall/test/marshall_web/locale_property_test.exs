defmodule MarshallWeb.LocalePropertyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Marshall.Localization, as: Locale

  @locales Locale.supported_locales()
  @typep selection :: %{override: String.t() | nil, browser: String.t(), expected: String.t()}
  @typep request_snapshot :: %{
           locale: String.t(),
           gettext: String.t(),
           localize: Localize.LanguageTag.t(),
           direction: :ltr | :rtl
         }

  # @cc [owner:ghuntley,label:verification] locale-negotiation-generated-oracle
  # Generated supported language pairs with distinct positive quality weights
  # MUST choose the larger weight independently of header order. Zero-quality,
  # unsupported and incompatible-script ranges MUST NOT displace that choice.
  property "weighted browser choices ignore ordering and refused language ranges" do
    preferred_index = draw("preferred locale", integer(0..(length(@locales) - 1)))
    offset = draw("different locale offset", integer(1..(length(@locales) - 1)))
    preferred = Enum.fetch!(@locales, preferred_index)
    secondary = Enum.fetch!(@locales, rem(preferred_index + offset, length(@locales)))
    high = draw("preferred quality", integer(2..999))
    low = draw("secondary quality", integer(1..(high - 1)))
    reversed? = draw("header order reversed", boolean())

    choices = ["#{preferred};q=#{quality(high)}", "#{secondary};q=#{quality(low)}"]
    choices = if reversed?, do: Enum.reverse(choices), else: choices

    header =
      Enum.join(["zz-ZZ", "zh-Hant;q=1", "ha-Arab;q=1", "en;q=0" | choices], ", ")

    assert Locale.negotiate(header) == preferred
    assert Locale.choose(nil, nil, header) == preferred
    assert Locale.choose(secondary, nil, header) == secondary
  end

  # @cc [owner:ghuntley,label:verification;security] locale-request-process-isolation
  # Interleaved request processes MUST retain their own validated Gettext and
  # Localize locale and direction after another process selects a different
  # language. Every request MUST reset both formatters, including a later
  # request that has no supported override or browser language.
  property "interleaved request histories isolate both locale backends and reset stale state" do
    index = draw("first request language", integer(0..(length(@locales) - 1)))
    first = Enum.fetch!(@locales, index)
    offset = draw("second language offset", integer(1..(length(@locales) - 1)))
    second = Enum.fetch!(@locales, rem(index + offset, length(@locales)))

    history =
      draw(
        "request selections",
        list_of(member_of([:override, :browser, :fallback]), min_length: 1, max_length: 8)
      )

    parent = self()
    workers = for _ <- 1..2, do: Task.async(fn -> request_worker(parent) end)

    try do
      for mode <- history do
        selections = [selection(mode, first, second), selection(mode, second, first)]

        for {worker, selected} <- Enum.zip(workers, selections) do
          send(worker.pid, {:select, selected})
        end

        for worker <- workers do
          pid = worker.pid
          assert_receive {:selected, ^pid}, 5_000
        end

        for worker <- workers, do: send(worker.pid, :snapshot)

        for {worker, selected} <- Enum.zip(workers, selections) do
          pid = worker.pid
          assert_receive {:snapshot, ^pid, actual}, 5_000
          assert actual.locale == selected.expected
          assert actual.gettext == selected.expected

          assert {:ok, expected_tag} =
                   Localize.validate_locale(Locale.formatting_locale(selected.expected))

          # Localize caches validated tags VM-wide under a case-folded key,
          # and Accept-Language negotiation validates lowercased ranges, so
          # `requested_locale_id` records whichever caller first resolved the
          # locale ("pt-br" or "pt-BR"). Compare the resolved identity.
          assert resolved_identity(actual.localize) == resolved_identity(expected_tag)
          assert actual.direction == if(selected.expected in ~w(ar ur arz), do: :rtl, else: :ltr)
        end
      end
    after
      for worker <- workers do
        send(worker.pid, :stop)
        Task.await(worker, 5_000)
      end
    end
  end

  @spec resolved_identity(Localize.LanguageTag.t()) :: Localize.LanguageTag.t()
  defp resolved_identity(%Localize.LanguageTag{} = tag), do: %{tag | requested_locale_id: nil}

  @spec quality(pos_integer()) :: String.t()
  defp quality(value), do: "0." <> String.pad_leading(Integer.to_string(value), 3, "0")

  @spec selection(:override | :browser | :fallback, String.t(), String.t()) :: selection()
  defp selection(:override, own, other), do: %{override: own, browser: other, expected: own}
  defp selection(:browser, own, _other), do: %{override: nil, browser: own, expected: own}
  defp selection(:fallback, _own, _other), do: %{override: nil, browser: "zz-ZZ", expected: "en"}

  @spec request_worker(pid()) :: :ok
  defp request_worker(parent) do
    receive do
      {:select, selected} ->
        conn =
          Plug.Test.conn(:get, "/")
          |> Plug.Test.init_test_session(%{})
          |> Plug.Conn.assign(:current_user, %{locale: selected.override})
          |> Plug.Conn.put_req_header("accept-language", selected.browser)
          |> MarshallWeb.LocalePlug.call(session: true)

        send(parent, {:selected, self()})

        receive do
          :snapshot ->
            send(parent, {:snapshot, self(), snapshot(conn)})
        after
          5_000 -> raise "locale request snapshot was not requested"
        end

        request_worker(parent)

      :stop ->
        :ok
    after
      5_000 -> raise "locale request worker was not stopped"
    end
  end

  @spec snapshot(Plug.Conn.t()) :: request_snapshot()
  defp snapshot(conn) do
    %{
      locale: conn.assigns.locale,
      gettext: Gettext.get_locale(MarshallWeb.Gettext),
      localize: Localize.get_locale(),
      direction: conn.assigns.direction
    }
  end
end
