-- Galactic Station deployment manifest.
-- Public software metadata only. Never place keys/passwords here.
-- The management console downloads these GitHub files and transfers them to
-- the selected host through authenticated modem management port 45822.

return {
  version = "3.0.1",
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
      {source = "station.lua", destination = "/usr/bin/station.lua"},
      {source = "station_rc.lua", destination = "/etc/rc.d/station.lua"}
    },
    witness = {
      {source = "witness.lua", destination = "/usr/bin/witness.lua"},
      {source = "witness_rc.lua", destination = "/etc/rc.d/witness.lua"}
    },
    module = {
      {source = "station_api.lua", destination = "/usr/lib/station_api.lua"}
    },
    module_agent = {
      {source = "module_agent.lua", destination = "/usr/bin/module_agent.lua"},
      {source = "module_agent_rc.lua", destination = "/etc/rc.d/module_agent.lua"}
    },
    archive = {
      {source = "station_log_collector.lua", destination = "/usr/lib/station_log_collector.lua"},
      {source = "station_log_collector_rc.lua", destination = "/etc/rc.d/station_log_collector.lua"}
    },
    safety = {
      {source = "examples/safety_rules.lua", destination = "/etc/station/safety_rules.lua"}
    },
    security = {
      {source = "examples/acl.lua", destination = "/etc/station/acl.lua"}
    },
    main_service = {
      {source = "main_service_monitor.lua", destination = "/usr/bin/main_service_monitor.lua"},
      {source = "main_service_monitor_rc.lua", destination = "/etc/rc.d/main_service_monitor.lua"}
    }
  }
}
