# Vision

Simple Prometheus observability for Elixir apps

## Getting started 

Add :vision to the list of dependencies in mix.exs:

```elixir
def deps do
  [
    {:vision, git: "https://github.com/pedro-gutierrez/vision.git", branch: "main"}
  ]
end
```

Then setup your connection to Grafana:

```elixir
config :myapp, Vision,
  grafana: [
    host: System.fetch_env!("GRAFANA_HOST"),
    token: System.fetch_env!("GRAFANA_TOKEN")
  ]
```

Define a module that will define both your metrics and dashboards:

```elixir
defmodule MyApp.Metrics do
  use Vision.Metrics,
    otp_app: :myapp,
    metrics: [
      [
        kind: :gauge,
        name: [:host, :memory],
        event: [:host, :usage],
        help: "Host memory",
        measurement: :memory,
        unit: :percent,
        thresholds: [50, 75, 90]
      ],
      ...
    ],
    dashboards: [
      some_folder: [
        overview: [
          variables: [
            ...
          ],
          rows: [
            host: [
               panels: [
                 [metric: [:host, :memory]] 
               ]
            ]
          ]
        ]
      ]
    ]
end
```

Finally add your metrics module to your supervision tree:

```elixir
children = [
  ...    
  MyApp.Metrics,
  ...
]

opts = [strategy: :one_for_one, name: ...]
Supervisor.start_link(children, opts)
```



