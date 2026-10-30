{ hosts }:
let
  # @cc [owner:ghuntley,label:observability] diagnostic-panel-unique-roster-ids
  # Diagnostic panel IDs MUST follow every generated duration and objective
  # panel, using the same source rosters as the dashboard. Adding a source MUST
  # NOT overwrite an existing panel through a duplicate ID.
  firstId = 14 + builtins.length (import ./durable-services.nix)
    + builtins.length (import ./candidate-sources.nix)
    + builtins.length (import ./slo-catalog.nix { inherit hosts; });
  mappings = builtins.listToAttrs (builtins.genList (i: {
    name = toString i;
    value = { text = builtins.elemAt [ "Ready" "Source missing" "Source stale" "Warming up"
      "Coverage gap" "No eligible requests" "Awaiting seven-day history"
      "Below 100 eligible requests" "Incomplete durations" "Histogram overflow"
      "Measurement unavailable" ] i;
      color = if i == 0 then "green" else if i < 3 then "red" else "orange";
    };
  }) 11);
  table = id: title: y: expr: {
    inherit id title;
    type = "table";
    description = "Metrics and traces are retained for 90 days. SLOs still evaluate seven days. Unknown measurements are never replaced with successful values.";
    gridPos = { h = 14; w = 24; x = 0; inherit y; };
    datasource = { type = "prometheus"; uid = "overalls-prometheus"; };
    targets = [{ refId = "A"; inherit expr; instant = true; format = "table"; }];
    transformations = [{ id = "organize"; options = { excludeByName = { Time = true; "__name__" = true; }; }; }];
    fieldConfig.defaults = { mappings = [{ type = "value"; options = mappings; }]; };
    options = { showHeader = true; sortBy = [{ displayName = "slo"; desc = false; }]; };
  };
in [
  (table firstId "Why measurements are unavailable · current source status" 0
    ''overalls:slo_status and (time() - timestamp(overalls:slo_status) < 90)'')
  ((table (firstId + 1) "Measurement evidence · requests, history days and freshness seconds" 14
    ''overalls:slo_evidence and (time() - timestamp(overalls:slo_evidence) < 90)'') // {
      fieldConfig.defaults = { decimals = 2; };
    })
  # @cc [owner:ghuntley,label:observability;reliability] browser-window-observation-panel
  # Browser conditions MUST display only guarded fixed-window measurements.
  # Missing measurements MUST remain absent, never show a successful condition
  # or imply a persistent consecutive failure streak.
  ((table (firstId + 2) "Browser journeys · fixed-window observations" 28
    ''overalls:browser_probe_diagnostic and (time() - timestamp(overalls:browser_probe_diagnostic) < 90)'') // {
      description = "Separate NixOS and Ubuntu observations: three failures without a success in 15 minutes, or no completion in 10 minutes. Missing data is unknown; these conditions do not measure a persistent failure streak.";
      fieldConfig.defaults = { mappings = [{ type = "value"; options = {
        "0" = { text = "Condition not observed"; color = "green"; };
        "1" = { text = "Condition observed"; color = "orange"; };
      }; }]; };
    })
]
