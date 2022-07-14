# Vision

Simple Prometheus observability for Elixir apps

## Installation 

Add :vision to the list of dependencies in mix.exs:

```elixir
def deps do
  [
    {:vision, git: "https://github.com/pedro-gutierrez/vision.git", branch: "main"}
  ]
end
```

## Configuration

Setup your connection to Grafana:

```elixir
config :myapp, Vision,
  grafana: [
    host: System.fetch_env!("GRAFANA_HOST"),
    token: System.fetch_env!("GRAFANA_TOKEN")
  ]
```

## Defining metrics and dashboards

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

Don't forget to add your module to your supervision tree:

```elixir
children = [
  ...    
  MyApp.Metrics,
  ...
]

opts = [strategy: :one_for_one, name: ...]
Supervisor.start_link(children, opts)
```

## Exposing metrics

In your router, add a path to your prometheus metrics:

```elixir
get "/metrics" do
  send_resp(conn, 200, Prometheus.Format.Text.format())
end
```


