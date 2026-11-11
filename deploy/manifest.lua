-- Galactic Station v4 deployment manifest.
-- Three-server topology: GS-CORE-01, GS-CORE-02, STATION-WITNESS.
-- Public source metadata only; never place private keys in this file.
return {
  version = "4.0.0",
  repository = "JA3297/galactic-station-core",
  common = {
    {source = "admin_crypto.lua", destination = "/usr/lib/admin_crypto.lua"},
    {source = "remote_admin_agent.lua", destination = "/usr/lib/remote_admin_agent.lua"},
    {source = "remote_admin_rc.lua", destination = "/etc/rc.d/remote_admin.lua"},
    {source = "station_logger.lua", destination = "/usr/lib/station_logger.lua"},
    {source = "remote_admin_diagnose.lua", destination = "/usr/bin/remote_admin_diagnose.lua"}
  },
  roles = {
    core = {
      {source = "v4/station_core.lua", destination = "/usr/bin/station.lua"},
      {source = "v4/station_rc.lua", destination = "/etc/rc.d/station.lua"},
      {source = "examples/safety_rules.lua", destination = "/etc/station/safety_rules.lua"},
      {source = "examples/acl.lua", destination = "/etc/station/acl.lua"}
    },
    witness = {
      {source = "v4/witness.lua", destination = "/usr/bin/witness.lua"},
      {source = "v4/witness_rc.lua", destination = "/etc/rc.d/witness.lua"},
      {source = "v4/station_log_collector.lua", destination = "/usr/lib/station_log_collector.lua"},
      {source = "v4/station_log_collector_rc.lua", destination = "/etc/rc.d/station_log_collector.lua"},
      {source = "station_admin.lua", destination = "/usr/bin/station_admin.lua"},
      {source = "admin_crypto_test.lua", destination = "/usr/bin/admin_crypto_test.lua"},
      {source = "admin_key_setup.lua", destination = "/usr/bin/admin_key_setup.lua"}
    }
  }
}
