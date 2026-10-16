defmodule GalleryWeb.Telemetry do
  @moduledoc """
  Metrics for LiveDashboard (`/dashboard`): Phoenix's and the VM's, and
  the gallery's A2UI traffic, which the pages report with
  `GalleryWeb.Telemetry.message/3`.
  """

  use Supervisor

  import Telemetry.Metrics

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    children = [{:telemetry_poller, measurements: [], period: 10_000}]
    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "The metrics LiveDashboard charts."
  def metrics do
    [
      counter("gallery.a2ui.message.count", tags: [:direction, :kind, :page]),
      summary("gallery.a2ui.message.duration",
        unit: {:native, :millisecond},
        tags: [:direction, :page]
      ),
      summary("phoenix.endpoint.stop.duration", unit: {:native, :millisecond}),
      summary("phoenix.live_view.handle_event.stop.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.handle_info.stop.duration", unit: {:native, :millisecond}),
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total")
    ]
  end

  @doc """
  Reports one A2UI message: `direction` is `:in` (agent to renderer) or
  `:out`, `page` the gallery page, `duration` the native time it took to
  apply (incoming) when known.
  """
  def message(direction, message, page, duration \\ 0) do
    :telemetry.execute(
      [:gallery, :a2ui, :message],
      %{count: 1, duration: duration},
      %{direction: direction, kind: kind(message), page: page}
    )
  end

  defp kind(%{} = message) do
    case message |> Map.delete("version") |> Map.keys() do
      [kind | _] -> kind
      [] -> "unknown"
    end
  end

  defp kind(_other), do: "unknown"
end
