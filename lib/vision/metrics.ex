defmodule Vision.Metrics do
  defmacro __using__(opts) do
    metrics = Keyword.fetch!(opts, :metrics)
    otp_app = Keyword.fetch!(opts, :otp_app)
    dashboards = Keyword.fetch!(opts, :dashboards)

    quote do
      use Task
      require Logger

      @metrics Enum.map(unquote(Macro.escape(metrics)), fn m ->
                 m
                 |> Keyword.put(:registry, :default)
                 |> Keyword.put(:id, m[:name])
                 |> Keyword.put(:name, m[:name] |> Enum.join("_") |> String.to_atom())
                 |> Keyword.put(:title, m[:help])
               end)
      @metrics_by_name Enum.reduce(@metrics, %{}, fn m, acc ->
                         acc
                         |> Map.put(m[:name], m)
                         |> Map.put(m[:id], m)
                       end)
      @metrics_by_event Enum.reduce(@metrics, %{}, fn m, acc ->
                          case m[:event] do
                            nil ->
                              acc

                            event ->
                              metrics = Map.get(acc, m[:event], [])
                              Map.put(acc, m[:event], [m | metrics])
                          end
                        end)
      @prometheus_modules %{
        gauge: Prometheus.Metric.Gauge,
        counter: Prometheus.Metric.Counter,
        histogram: Prometheus.Metric.Histogram
      }

      @otp_app unquote(otp_app)
      @dashboards unquote(dashboards)

      def start_link(_) do
        Task.start_link(__MODULE__, :run, [])
      end

      def run do
        Prometheus.Registry.clear()

        for metric <- @metrics do
          m = Map.fetch!(@prometheus_modules, metric[:kind])
          m.new(metric)
        end

        :telemetry.attach_many(
          __MODULE__,
          @metrics
          |> Enum.filter(fn m -> m[:event] != nil end)
          |> Enum.map(fn m -> m[:event] end),
          &__MODULE__.export_metric_value/4,
          nil
        )

        upload_dashboards()
      end

      def upload_dashboards do
        for {folder, dashboards} <- @dashboards do
          folder
          |> folder_json()
          |> create_folder()
          |> print_grafana_error(ignore: [412])

          for {name, spec} <- dashboards do
            [title: name]
            |> Keyword.merge(spec)
            |> dashboard_json(folder: folder)
            |> create_dashboard()
            |> print_grafana_error(ignore: [])
          end
        end
      end

      defp ignore_error?(code, opts) do
        code < 400 || Enum.member?(opts[:ignore] || [], code)
      end

      defp print_grafana_error({:ok, %{status_code: code} = resp}, opts) do
        with false <- ignore_error?(code, opts) do
          resp
          |> Map.drop([:request])
          |> print_grafana_error()
        end
      end

      defp print_grafana_error({:error, error}, _opts) do
        print_grafana_error(error)
      end

      defp print_grafana_error(error) do
        Logger.error("Grafana error: #{inspect(error)}")
      end

      def export_metric_value(event, measurement, meta, _) do
        for m <- Map.get(@metrics_by_event, event, []) do
          kind = m[:kind]
          labels = labels(m, meta)
          default = default(kind)
          value = value(m, measurement, default)
          export(kind, m[:name], labels, value)
        end
      end

      defp export(kind, name, labels, :drop) do
        Logger.warn(
          "Dropping #{kind} #{name} with labels #{inspect(labels)} because of missing value"
        )

        :ok
      end

      defp export(kind, name, :drop, value) do
        Logger.warn(
          "Dropping #{kind} #{name} with value #{inspect(value)} because of missing labels"
        )

        :ok
      end

      defp export(:gauge, name, labels, value) do
        Prometheus.Metric.Gauge.set([name: name, labels: labels], value)
      end

      defp export(:counter, name, labels, value) do
        Prometheus.Metric.Counter.inc([name: name, labels: labels], value)
      end

      defp export(:histogram, name, labels, value) do
        Prometheus.Metric.Histogram.observe([name: name, labels: labels], value)
      end

      defp default(:counter), do: 1
      defp default(_), do: nil

      defp value(m, measurement, default \\ nil) do
        v = measurement[m[:measurement]]

        with nil <-
               (case m[:map] do
                  nil -> v
                  values -> values[v]
                end),
             nil <- default,
             do: :drop
      end

      defp labels(m, meta) do
        case m[:labels] do
          nil ->
            []

          labels ->
            with [] <-
                   labels
                   |> Enum.map(fn label -> meta[label] end)
                   |> Enum.reject(&is_nil/1) do
              :drop
            end
        end
      end

      defp folder_json(name) do
        title = title(name)
        %{title: title, uid: uid(title)}
      end

      defp dashboard_json(spec, opts) do
        %{
          dashboard: %{
            uid: uid(title(spec[:title])),
            title: title(spec[:title]),
            tags: spec[:tags],
            refresh: "5s",
            time: %{from: "now-1h", to: :now},
            panels:
              spec[:rows]
              |> Enum.with_index()
              |> Enum.map(&dashboard_row_json/1)
              |> List.flatten(),
            templating: %{
              list: (spec[:variables] || []) |> Enum.map(&dashboard_variable/1)
            }
          },
          folderUid: uid(title(opts[:folder])),
          overwrite: true
        }
      end

      defp dashboard_row_json({{name, spec}, row}) do
        panels = spec[:panels]

        header = %{
          type: :row,
          title: title(name),
          gridPos: row_position(row)
        }

        header =
          case spec[:repeat] do
            nil ->
              header

            repeat ->
              header
              |> Map.put(:repeat, "#{repeat}")
              |> Map.put(:title, "$#{repeat}")
          end

        [
          header
          | panels
            |> Enum.with_index()
            |> Enum.map(&dashboard_panel_json(&1, row: row, row_spec: spec, panels: panels))
        ]
      end

      defp metric!(spec) do
        metric_name = spec[:metric] || List.first(spec[:metrics])
        metric = Map.get(@metrics_by_name, metric_name, nil)

        unless metric do
          raise """
            "No such metric #{inspect(metric_name)} in #{inspect(Map.keys(@metrics_by_name))}"
          """
        end

        metric
      end

      defp dashboard_variable({name, spec}) do
        metric = metric!(spec)

        %{
          datasource: "Prometheus",
          definition: "label_values(#{metric[:name]}, #{name})",
          hide: 0,
          includeAll: spec[:repeat] || false,
          multi: spec[:repeat] || false,
          name: name,
          options: [],
          query: "label_values(#{metric[:name]}, #{name})",
          refresh: 1,
          sort: 0,
          type: "query"
        }
      end

      def row_position(row_index) do
        %{y: row_index * 9}
      end

      defp panel_position(row_index, panel_index, panels) do
        w = trunc(24 / length(panels))
        x = panel_index * w
        %{x: x, y: row_index * 9 + 1, h: 8, w: w}
      end

      defp dashboard_panel_json({spec, panel}, opts \\ []) do
        opts = Enum.into(opts, %{})

        row = opts[:row]
        panels = opts[:panels]

        metric = metric!(spec)

        metrics =
          cond do
            spec[:metric] != nil ->
              [metric]

            spec[:metrics] != nil ->
              Enum.map(spec[:metrics], fn metric -> metric!(metric: metric) end)
          end

        %{
          datasource: "Prometheus",
          type: metric[:visualization] || :gauge,
          title: spec[:title] || metric[:title],
          targets: Enum.map(metrics, &with_target_expression(&1, opts[:row_spec])),
          fieldConfig: %{
            defaults:
              defaults()
              |> with_customisations(metric)
              |> with_unit(metric)
              |> with_value_mappings(metric)
              |> with_thresholds(metric)
              |> with_max(metric)
              |> with_decimals(metric)
          },
          options:
            options()
            |> with_threshold_markers(metric)
            |> with_graph_mode(metric)
            |> maybe_hide_legend(metric)
        }
        |> Map.put(:gridPos, panel_position(row, panel, panels))
      end

      defp defaults, do: %{}
      defp options, do: %{justifyMode: :center}

      defp with_target_expression(metric, row) do
        %{}
        |> with_expression(metric, row)
        |> with_legend(metric)
      end

      defp filters_expression(row) do
        case row[:filter] do
          nil ->
            ""

          filters ->
            filters =
              filters
              |> Enum.map(fn var -> "#{var}=\"$#{var}\"" end)
              |> Enum.join(",")

            "{#{filters}}"
        end
      end

      defp with_expression(expr, metric, row) do
        filters = filters_expression(row)

        case metric[:expression] do
          nil ->
            %{expr: "#{metric[:name]}#{filters}"}

          :rate ->
            %{expr: "rate(#{metric[:name]}#{filters}[$__rate_interval])"}

          {:quantile, q} ->
            %{
              expr:
                "histogram_quantile(#{q}, sum(increase(#{metric[:name]}_bucket#{filters}[$__rate_interval])) by (le))"
            }

          expr when is_binary(expr) ->
            %{expr: expr}

          other ->
            raise """
              Expression #{inspect(other)} not supported in metric: #{inspect(metric)}
            """
        end
      end

      defp with_legend(expr, metric) do
        case metric[:legend] || metric[:labels] do
          nil ->
            expr

          legend ->
            legend_expr = legend_expr(legend)
            Map.put(expr, :legendFormat, legend_expr)
        end
      end

      defp legend_expr(label) when is_atom(label) do
        legend_expr([label])
      end

      defp legend_expr(labels) when is_list(labels) do
        labels
        |> Enum.map(fn label -> "{{ #{label} }}" end)
        |> Enum.join(" ")
      end

      defp with_customisations(defaults, metric) do
        Map.put(defaults, :custom, %{
          lineInterpolation: :smooth
        })
      end

      defp with_unit(defaults, metric) do
        case metric[:unit] do
          nil -> defaults
          unit -> Map.put(defaults, :unit, unit)
        end
      end

      defp with_value_mappings(defaults, metric) do
        case metric[:map] do
          nil ->
            defaults

          mappings ->
            Map.put(defaults, :mappings, [
              %{
                type: :value,
                options:
                  mappings
                  |> Enum.with_index()
                  |> Enum.reduce(%{}, fn {{label, value}, index}, acc ->
                    mapping = %{index: index, text: title(label)}

                    mapping =
                      case get_in(metric, [:colors, label]) do
                        nil -> mapping
                        color -> Map.put(mapping, :color, color)
                      end

                    Map.put(acc, "#{value}", mapping)
                  end)
              }
            ])
        end
      end

      defp with_thresholds(defaults, metric) do
        case metric[:thresholds] do
          nil ->
            Map.put(defaults, :thresholds, %{
              mode: :absolute,
              steps: [
                %{
                  color: Keyword.get(metric, :default_color, :green),
                  value: nil
                }
              ]
            })

          [yellow, red, _] when is_integer(yellow) ->
            Map.put(defaults, :thresholds, %{
              mode: :absolute,
              steps: [
                %{
                  color: :green,
                  value: nil
                },
                %{
                  color: :yellow,
                  value: yellow
                },
                %{
                  color: :red,
                  value: red
                }
              ]
            })

          colors ->
            Map.put(defaults, :thresholds, %{
              mode: :absolute,
              steps: Enum.map(colors, fn {color, value} -> %{color: color, value: value} end)
            })
        end
      end

      defp with_max(defaults, metric) do
        case metric[:thresholds] do
          nil ->
            defaults

          thresholds ->
            max = List.last(thresholds)

            value =
              case max do
                {_, value} when is_integer(value) -> value
                value when is_integer(value) -> value
              end

            Map.put(defaults, :max, value)
        end
      end

      defp with_decimals(defaults, metric) do
        case metric[:decimals] do
          nil ->
            defaults

          decimals ->
            Map.put(defaults, :decimals, decimals)
        end
      end

      defp with_threshold_markers(options, metric) do
        {labels, markers} =
          case {metric[:thresholds], Keyword.get(metric, :threshold_markers, true)} do
            {_, false} -> {false, false}
            {nil, true} -> {false, false}
            {_, true} -> {false, true}
          end

        options
        |> Map.put(:showThresholdLabels, labels)
        |> Map.put(:showThresholdMarkers, markers)
      end

      defp with_graph_mode(options, metric) do
        mode = metric[:graph] || :none
        Map.put(options, :graphMode, mode)
      end

      defp maybe_hide_legend(options, metric) do
        case metric[:labels] do
          nil -> Map.put(options, :legend, %{displayMode: :hidden})
          _ -> options
        end
      end

      defp create_folder(json), do: grafana_post("/api/folders", json)

      defp create_dashboard(json), do: grafana_post("/api/dashboards/db", json)

      defp grafana_post(path, json) do
        path
        |> grafana_url()
        |> HTTPoison.post(
          Jason.encode!(json),
          [
            {"Content-Type", "application/json"},
            {"Accept", "application/json"},
            {"Authorization", "Bearer " <> grafana_opt(:token)}
          ]
        )
      end

      defp grafana_url(path), do: grafana_opt(:host) <> path
      defp title(name), do: name |> to_string() |> String.capitalize()
      defp uid(title), do: "G#{:erlang.phash2(title)}"

      defp grafana_opt(key) do
        @otp_app
        |> Application.get_env(Torch)
        |> Keyword.fetch!(:grafana)
        |> Keyword.fetch!(key)
      end
    end
  end
end
