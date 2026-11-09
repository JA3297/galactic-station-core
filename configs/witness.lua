-- Cluster witness configuration. Use exactly the same network_id as all core computers.
return {
  network_id = "GALACTIC-STATION-01",
  boot_guard = 10,          -- Wait after witness startup before issuing any lease.
  witness_lease = 8,         -- Witness-side ownership window, seconds of game uptime.
  grant_ttl = 5,             -- Active node demotes itself if it does not hear renewal.
  request_freshness = 6,
  pairs = {
    ["PAIR-CMD"]  = {A = "CORE-A1", B = "CORE-B1", preferred_side = "A"},
    ["PAIR-NET"]  = {A = "CORE-A2", B = "CORE-B2", preferred_side = "A"},
    ["PAIR-TLM"]  = {A = "CORE-A3", B = "CORE-B3", preferred_side = "A"},
    ["PAIR-DATA"] = {A = "CORE-A4", B = "CORE-B4", preferred_side = "A"},
    ["PAIR-SAFE"] = {A = "CORE-A5", B = "CORE-B5", preferred_side = "A"},
    ["PAIR-UTIL"] = {A = "CORE-A6", B = "CORE-B6", preferred_side = "A"},
    ["PAIR-OPS"]  = {A = "CORE-A7", B = "CORE-B7", preferred_side = "A"},
    ["PAIR-SEC"]  = {A = "CORE-A8", B = "CORE-B8", preferred_side = "A"}
  }
}
