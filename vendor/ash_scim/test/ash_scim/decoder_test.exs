# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.DecoderTest do
  use ExUnit.Case, async: true

  alias AshScim.Decoder
  alias AshScim.Test.Example.User

  describe "decode/2 — attrs" do
    test "extracts simple top-level mappings into Ash attribute params" do
      decoded =
        Decoder.decode(User, %{
          "userName" => "alice@example.com",
          "active" => false,
          "externalId" => "okta-abc-123"
        })

      assert decoded.attrs == %{
               email: "alice@example.com",
               active: false,
               scim_external_id: "okta-abc-123"
             }

      assert decoded.relationships == %{}
    end

    test "extracts complex sub-attributes into the corresponding Ash attributes" do
      decoded =
        Decoder.decode(User, %{
          "name" => %{"givenName" => "Alice", "familyName" => "Anderson"}
        })

      assert decoded.attrs == %{first_name: "Alice", last_name: "Anderson"}
    end

    test "ignores unknown SCIM attributes silently (RFC 7644 §3.1)" do
      decoded =
        Decoder.decode(User, %{
          "userName" => "alice@example.com",
          "preferredLanguage" => "en-US",
          "title" => "Engineer"
        })

      assert decoded.attrs == %{email: "alice@example.com"}
    end

    test "returns empty attrs and relationships for a body with no mapped fields" do
      assert %{attrs: %{}, relationships: %{}} = Decoder.decode(User, %{})
      assert %{attrs: %{}, relationships: %{}} = Decoder.decode(User, %{"unknown" => 123})
    end

    test "handles missing complex object gracefully" do
      decoded = Decoder.decode(User, %{"userName" => "alice@example.com"})
      assert decoded.attrs == %{email: "alice@example.com"}
    end
  end

  describe "decode/2 — relationship-backed multivalued with mirror_primary_to" do
    test "decodes each entry into a relationship input row" do
      decoded =
        Decoder.decode(User, %{
          "emails" => [
            %{"value" => "alice@example.com", "primary" => true, "type" => "work"},
            %{"value" => "alice+alt@example.com", "primary" => false, "type" => "home"}
          ]
        })

      assert decoded.relationships == %{
               emails: [
                 %{value: "alice@example.com", primary: true, type: "work"},
                 %{value: "alice+alt@example.com", primary: false, type: "home"}
               ]
             }
    end

    test "mirrors the explicit primary entry's value to the parent attr" do
      decoded =
        Decoder.decode(User, %{
          "emails" => [
            %{"value" => "alice+alt@example.com", "primary" => false},
            %{"value" => "alice@example.com", "primary" => true}
          ]
        })

      assert decoded.attrs == %{email: "alice@example.com"}
    end

    test "with no explicit primary, mirrors the lex-sorted first entry's value" do
      decoded =
        Decoder.decode(User, %{
          "emails" => [
            %{"value" => "zach@example.com"},
            %{"value" => "alice@example.com"}
          ]
        })

      assert decoded.attrs == %{email: "alice@example.com"}
    end

    test "skips mirror when no entry has a value sub-attribute" do
      decoded = Decoder.decode(User, %{"emails" => [%{"primary" => false}]})

      assert decoded.attrs == %{}
    end

    # Marshall-local: an explicit empty list is a full replacement with no rows.
    test "an explicitly empty list decodes to an empty relationship input" do
      assert Decoder.decode(User, %{"emails" => []}).relationships == %{emails: []}
    end

    test "a non-empty list with no decodable entries is ignored" do
      assert Decoder.decode(User, %{"emails" => [%{"display" => "x"}]}).relationships == %{}
    end
  end
end
