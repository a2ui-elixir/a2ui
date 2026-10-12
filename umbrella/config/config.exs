import Config

# Shared umbrella configuration.

if Mix.env() == :test do
  # Keep test output readable; conformance harness reports its own summary.
  config :logger, level: :warning
end
