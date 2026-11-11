-- Galactic Station v4 unified primary controller.
-- All supervisory services are consolidated into this one active/standby pair.
return {
  node_id = "GS-CORE-01",
  pair_id = "PAIR-CMD",
  side = "A",
  role = "command",
  network_id = "GALACTIC-STATION-01",
  services = {
    command = true,
    coordination = true,
    registry = true,
    network = true,
    communications = true,
    network_monitor = true,
    telemetry = true,
    health = true,
    archive = true,
    events = true,
    backup = true,
    safety = true,
    alarms = true,
    emergency = true,
    resources = true,
    utilities = true,
    power = true,
    scheduling = true,
    display = true,
    maintenance = true,
    security = true,
    configuration = true,
    software = true,
    time = true,
    life_support = true
  },
  expected_nodes = {"GS-CORE-01", "GS-CORE-02"}
}
