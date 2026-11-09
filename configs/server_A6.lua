-- Resources and Utilities server / Rack A
return {
  node_id = "CORE-A6",
  pair_id = "PAIR-UTIL",
  side = "A",
  role = "resources",
  network_id = "GALACTIC-STATION-01",
  services = {resources = true, utilities = true, power = true, scheduling = true},
  expected_nodes = {"CORE-A1", "CORE-A2", "CORE-A3", "CORE-A4", "CORE-A5", "CORE-A6", "CORE-A7", "CORE-A8", "CORE-B1", "CORE-B2", "CORE-B3", "CORE-B4", "CORE-B5", "CORE-B6", "CORE-B7", "CORE-B8"}
}
