defmodule MarshallWeb.PublicEndpointTest do
  use MarshallWeb.ConnCase, async: true

  test "browser endpoint refuses machine APIs before JSON parsing or credentials" do
    for service <- ["provisioners", "ssh", "ziggy", "audi", "fleet"] do
      response =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer synthetic-fixture")
        |> put_req_header("x-forwarded-for", "127.0.0.1")
        |> post("https://localhost/api/#{service}/v1/identity", "invalid-json")

      assert response.status == 404
      assert response.resp_body == "unavailable\n"
      assert get_resp_header(response, "cache-control") == ["no-store"]
      assert get_resp_header(response, "set-cookie") == []
    end
  end

  test "every browser endpoint response asks search engines not to index" do
    directive = "noindex, nofollow, noarchive, nosnippet, noimageindex"

    for path <- ["/", "/sign-in", "/robots.txt", "/health/live", "/api/fleet/v1/identity"] do
      response = get(build_conn(), "https://localhost" <> path)
      assert get_resp_header(response, "x-robots-tag") == [directive]
    end

    # The signed-out root redirects to the launch entry; the sign-in page renders
    # the root layout, which repeats the directive as a robots meta tag.
    assert redirected_to(get(build_conn(), "https://localhost/")) == "/launch/entry"

    assert html_response(get(build_conn(), "https://localhost/sign-in"), 200) =~
             ~s(<meta name="robots" content="#{directive}">)
  end

  # @cc [owner:ghuntley,label:verification] live-socket-has-no-long-poll
  # The browser endpoint MUST NOT serve the LiveView long-poll transport:
  # replicas share no PubSub, so a long-poll session cannot be resumed.
  test "LiveView socket offers no long-poll transport" do
    refute Enum.any?(MarshallWeb.Endpoint.__sockets__(), fn {path, _, opts} ->
             path == "/live" and opts[:longpoll]
           end)

    for method <- [:get, :post] do
      response = dispatch(build_conn(), MarshallWeb.Endpoint, method, "/live/longpoll", %{})
      assert response.status == 404
    end
  end
end
