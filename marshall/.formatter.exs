[
  import_deps: [
    :ash_paper_trail,
    :cinder,
    :ash_state_machine,
    :ash_oban,
    :oban,
    :ash_admin,
    :ash_authentication_phoenix,
    :ash_authentication,
    :ash_scim,
    :ash_postgres,
    :ash_phoenix,
    :ash,
    :reactor,
    :ecto,
    :ecto_sql,
    :phoenix
  ],
  locals_without_parens: [control_plane: 2, internal: 1, service: 2, record: 3, refused: 1],
  export: [
    locals_without_parens: [control_plane: 2, internal: 1, service: 2, record: 3, refused: 1]
  ],
  subdirectories: ["priv/*/migrations"],
  plugins: [Spark.Formatter, Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "*.{heex,ex,exs}",
    "{config,lib,test,scripts}/**/*.{heex,ex,exs}",
    "priv/*/seeds.exs",
    "../scripts/*.{ex,exs}",
    "../.formatter.exs"
  ]
]
