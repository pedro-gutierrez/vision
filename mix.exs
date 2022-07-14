defmodule Vision.MixProject do
  use Mix.Project

  def project do
    [
      app: :vision,
      version: "0.1.0",
      elixir: "~> 1.12",
      start_permanent: true,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :httpoison]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:prometheus_ex, "~> 3.0.5"},
      {:telemetry, "~> 1.0", override: true},
      {:telemetry_poller, "~> 1.0", override: true}
    ]
  end
end
