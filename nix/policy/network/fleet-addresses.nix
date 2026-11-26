# @cc [owner:ghuntley,label:security] fleet-address-names
# Every fleet public address MUST be named here by logical name and secret
# name only; the values live in the shared fleet-addresses SOPS document.
# Each host also declares its own uplink prefix and gateway in host.json.
{
  salopettesPrimary = "SALOPETTES_IPV4";
  overallsPrimary = "OVERALLS_PRIMARY_IPV4";
  overallsService = "OVERALLS_SERVICE_IPV4";
  geoffreyHuntley = "GEOFFREY_HUNTLEY_IPV4";
  geoffreyHuntleySecondary = "GEOFFREY_HUNTLEY_SECONDARY_IPV4";
  geoffreyHuntleyTertiary = "GEOFFREY_HUNTLEY_TERTIARY_IPV4";
}
