defmodule Vision.Poller do
  defmacro __using__(opts) do
    period = Keyword.fetch!(opts, :period)

    measurements =
      opts
      |> Keyword.fetch!(:measurements)
      |> Enum.map(fn
        {_, _, [{_, _, mod}, fun_name, measurement, event]} ->
          [module: Module.concat(mod), fun_name: fun_name, measurement: measurement, event: event]

        {_, _, [{_, _, mod}, fun_name, event]} ->
          [module: Module.concat(mod), fun_name: fun_name, event: event]
      end)

    [
      quote do
        @period unquote(period)
        @measurements unquote(Macro.escape(measurements))
        require Logger

        def child_spec(_) do
          %{
            id: __MODULE__,
            start:
              {:telemetry_poller, :start_link,
               [
                 [
                   period: @period,
                   vm_measurements: [],
                   measurements:
                     Enum.map(@measurements, fn m ->
                       {__MODULE__, m[:fun_name], []}
                     end)
                 ]
               ]}
          }
        end
      end
      | Enum.map(measurements, fn m ->
          quote do
            def unquote(m[:fun_name])() do
              case unquote(m[:module]).unquote(m[:fun_name])() do
                nil ->
                  :ok

                values when is_list(values) ->
                  for v <- values do
                    {measurement, metadata} =
                      case unquote(m[:measurement]) do
                        nil -> {v, %{}}
                        measurement -> Map.split(v, [measurement])
                      end

                    :telemetry.execute(unquote(m[:event]), measurement, metadata)
                  end

                v when is_map(v) ->
                  {measurement, metadata} =
                    case unquote(m[:measurement]) do
                      nil -> {v, %{}}
                      measurement -> Map.split(v, [unquote(m[:measurement])])
                    end

                  :telemetry.execute(unquote(m[:event]), measurement, metadata)

                v ->
                  :telemetry.execute(unquote(m[:event]), %{unquote(m[:measurement]) => v})
              end
            rescue
              error ->
                Logger.warn("Error polling #{inspect(unquote(m[:event]))}: #{inspect(error)}")
                :ok
            end
          end
        end)
    ]
  end
end
