-- Archive and Records server / Rack B
return {
  node_id = "CORE-B4",
  pair_id = "PAIR-DATA",
  side = "B",
  role = "archive",
  network_id = "GALACTIC-STATION-01",
  services = {archive = true, events = true, backup = true},
  expected_nodes = {"CORE-A1", "CORE-A2", "CORE-A3", "CORE-A4", "CORE-A5", "CORE-A6", "CORE-A7", "CORE-A8", "CORE-B1", "CORE-B2", "CORE-B3", "CORE-B4", "CORE-B5", "CORE-B6", "CORE-B7", "CORE-B8"}
}
