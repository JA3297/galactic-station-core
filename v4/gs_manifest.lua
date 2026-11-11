return {
  version = "4.0.4",
  common = {
    {source="data_card_check.lua", destination="/usr/bin/data_card_check.lua"},
    {source="gs_crypto.lua", destination="/usr/lib/gs_crypto.lua"},
    {source="gs_life.lua", destination="/usr/lib/gs_life.lua"},
    {source="gsd.lua", destination="/usr/bin/gsd.lua"},
    {source="gs_rc.lua", destination="/etc/rc.d/gs.lua"}
  },
  hub = {
    {source="gs.lua", destination="/usr/bin/gs.lua"},
    {source="gs_crypto_test.lua", destination="/usr/bin/gs_crypto_test.lua"},
    {source="gs_manifest.lua", destination="/usr/lib/gs_manifest.lua"}
  }
}
