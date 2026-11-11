-- Galactic Station v4 operations / witness server.
-- One witness arbitrates the single unified primary/standby controller pair.
return {
  node_id = "STATION-WITNESS",
  network_id = "GALACTIC-STATION-01",
  boot_guard = 10,
  witness_lease = 8,
  grant_ttl = 5,
  request_freshness = 6,
  pairs = {
    ["PAIR-CMD"] = {
      A = "GS-CORE-01",
      B = "GS-CORE-02",
      preferred_side = "A"
    }
  }
}
