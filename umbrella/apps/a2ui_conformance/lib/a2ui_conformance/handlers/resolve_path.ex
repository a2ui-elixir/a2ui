defmodule A2UIConformance.Handlers.ResolvePath do
  @moduledoc false

  # `resolve_path` (reference harness L1231-1245): resolves `args.path`
  # against `args.contextPath` (or `args.context_path`, default `"/"`)
  # and compares with `expect` — either the string itself or a map with a
  # `result` key.

  @behaviour A2UIConformance.Handler

  import ExUnit.Assertions

  alias A2UIConformance.Case
  alias A2UICore.Resolution.DataContext

  @impl true
  def run(%Case{raw: raw}, _context) do
    args = raw["args"] || %{}
    context_path = args["contextPath"] || args["context_path"]
    context = DataContext.new(context_path || "/")
    resolved = DataContext.resolve_path(context, args["path"] || "")

    case raw["expect"] do
      %{"result" => expected} -> assert resolved == expected
      nil -> :ok
      expected -> assert resolved == expected
    end

    :ok
  end
end
