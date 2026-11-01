import Config

config :overalls_diagnostics, events_catalog: Lilly.Events

config :ash, default_string_length_count: :codepoints

config :lilly, ash_domains: [Lilly.Lifecycle]

config :logger,
  handle_otp_reports: true,
  handle_sasl_reports: true,
  translators: [{Lilly.OTPReports, :translate}, {Logger.Translator, :translate}]

config :logger, :default_handler,
  config: [type: :standard_error],
  formatter: {Overalls.Diagnostics.Formatter, catalog: Lilly.Events, service: :lilly}

# Test builds only: inside a user namespace whose uid map has no uid 0
# (the Buck2 bubblewrap test sandbox), root-owned system files appear owned by
# the overflow uid. Read at compile time (Lilly.Host.RootOwner), never by a
# release.
if config_env() == :test do
  config :lilly, Lilly.Host.RootOwner, unmapped_root: true
end

if config_env() in [:dev, :test] do
  config :covenant,
    contracts_dir: "contracts",
    test_paths: ["test/contract"],
    sibling_dir: false,
    results_dir: "_build/covenant/results"
end
