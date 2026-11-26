# @cc [owner:ghuntley,label:security] reviewed-fleet-network-sources
# Fleet-wide public-network grants MUST name reviewed fleet addresses (logical
# names in the shared fleet-addresses SOPS document, see fleet-addresses.nix)
# with a human-readable comment. Address literals, private keys and dynamic DNS
# names MUST NOT appear.
{
  overalls = {
    name = "overallsPrimary";
    comment = "Overalls fleet host";
  };
  geoffreyHuntley = {
    name = "geoffreyHuntley";
    comment = "Geoffrey Huntley operator access";
  };
  geoffreyHuntleySecondary = {
    name = "geoffreyHuntleySecondary";
    comment = "Geoffrey Huntley secondary operator access";
  };
  geoffreyHuntleyTertiary = {
    name = "geoffreyHuntleyTertiary";
    comment = "Geoffrey Huntley tertiary operator access";
  };
}
