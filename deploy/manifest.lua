-- Galactic Station deployment manifest.
-- This file is public source metadata. Never put passwords or keys here.
-- station_admin.lua downloads these files from raw.githubusercontent.com and
-- transfers them to targets over the authenticated in-game modem network.

return {
  version = "2.1.1",
  repository = "JA3297/galactic-station-core",
  common = {
    {source = "admin_crypto.lua", destination = "/usr/lib/admin_crypto.lua"},
    {source = "remote_admin_agent.lua", destination = "/usr/lib/remote_admin_agent.lua"},
    {source = "remote_admin_rc.lua", destination = "/etc/rc.d/remote_admin.lua"},
    {source = "station_logger.lua", destination = "/usr/lib/station_logger.lua"}
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
      {source = "station_api.lua", destination = "/usr/lib/station_api.lua"},
      {source = "module_agent.lua", destination = "/usr/bin/module_agent.lua"}
    },
    archive = {
      {source = "station_log_collector.lua", destination = "/usr/lib/station_log_collector.lua"},
      {source = "station_log_collector_rc.lua", destination = "/etc/rc.d/station_log_collector.lua"}
    },
    main_service = {
      {source = "main_service_monitor.lua", destination = "/usr/bin/main_service_monitor.lua"},
      {source = "main_service_monitor_rc.lua", destination = "/etc/rc.d/main_service_monitor.lua"}
    }
  }
}
