-- Copy to /etc/station/safety_rules.lua on BOTH safety-pair computers.
-- Rules are deliberately generic. Add the telemetry field names and limits
-- that your own module-local controllers publish.
-- A rule is evaluated when telemetry is received by the safety pair.
return {
  -- Example only; uncomment and replace field/limits for your station:
  -- {
  --   id = "EXAMPLE-HIGH",
  --   field = "example_numeric_field",
  --   min = 0,
  --   max = 100,
  --   severity = "WARNING",
  --   label = "Example parameter outside approved limits"
  -- }
}
