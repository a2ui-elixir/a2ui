defmodule A2UIPhoenix.MCPApp do
  @moduledoc """
  The host side of the MCP catalog's `McpApp` component: what the
  component renders from its props, and the checks the host makes on
  what the embedded app sends over the MCP Apps bridge (see the A2UI
  MCP App component specification). `A2UIPhoenix.Session.mcp_app_request/5`
  acts on the requests; `priv/static/a2ui_phoenix.js` runs the bridge in
  the browser.

  Every payload the app sends is checked before the host acts on it: no
  `__proto__`, `constructor` or `prototype` key at any depth, at most 10
  levels of nesting, and at most 64 KiB of JSON.
  """

  alias A2UICore.Resolution.DataContext
  alias A2UICore.State.{DataModel, Surface}

  @moduledoc since: "0.1.0"

  @max_depth 10
  @max_bytes 65_536
  @forbidden_keys ["__proto__", "constructor", "prototype"]
  @reserved_keys ["toolInput", "toolResult", "modelContext"]

  @doc """
  The app's HTML: `htmlContent`, decoded when it starts with
  `url_encoded:`, or `nil` when there is none.

      iex> A2UIPhoenix.MCPApp.html(%{"htmlContent" => "url_encoded:%3Cp%3EHi%3C%2Fp%3E"})
      "<p>Hi</p>"
  """
  @spec html(map()) :: String.t() | nil
  def html(%{"htmlContent" => "url_encoded:" <> encoded}) do
    # As `decodeURIComponent`: a malformed escape or invalid UTF-8 fails.
    with false <- String.match?(encoded, ~r/%(?![0-9A-Fa-f]{2})/),
         decoded = URI.decode(encoded),
         true <- String.valid?(decoded) do
      decoded
    else
      _malformed -> nil
    end
  end

  def html(%{"htmlContent" => html}) when is_binary(html), do: html
  def html(_props), do: nil

  @doc """
  The data model paths the app binds (`data.paths`), by key, resolved
  against `context` (the component's data scope).
  """
  @spec paths(map(), DataContext.t()) :: %{optional(String.t()) => String.t()}
  def paths(props, %DataContext{} = context) do
    case get_in(props, ["data", "paths"]) do
      %{} = paths ->
        for {key, path} <- paths, is_binary(path), into: %{} do
          {key, DataContext.resolve_path(context, path)}
        end

      _none ->
        %{}
    end
  end

  @doc """
  The current values of the bound paths, by key — what the host keeps
  the app in step with. `modelContext` only flows from the app, so it is
  left out.
  """
  @spec state(map(), Surface.t(), DataContext.t()) :: map()
  def state(props, %Surface{} = surface, %DataContext{} = context) do
    props
    |> paths(context)
    |> Map.delete("modelContext")
    |> Map.new(fn {key, path} -> {key, read(surface, path)} end)
  end

  @doc "The value at `path` of the surface's data model (`nil` when absent)."
  @spec read(Surface.t(), String.t()) :: term()
  def read(%Surface{data_model: model}, path) do
    case DataModel.get(model, path) do
      {:ok, value} -> value
      {:error, _error} -> nil
    end
  end

  @doc "The reserved `data.paths` keys: #{Enum.map_join(@reserved_keys, ", ", &"`#{&1}`")}."
  @spec reserved_keys() :: [String.t()]
  def reserved_keys, do: @reserved_keys

  @doc """
  Checks a payload from the app; `{:error, reason}` when it is unsafe.

      iex> A2UIPhoenix.MCPApp.check_payload(%{"a" => [1, 2]})
      :ok
      iex> A2UIPhoenix.MCPApp.check_payload(%{"__proto__" => %{}})
      {:error, "forbidden key '__proto__'"}
  """
  @spec check_payload(term()) :: :ok | {:error, String.t()}
  def check_payload(payload) do
    with :ok <- check_shape(payload, 0) do
      if byte_size(Jason.encode!(payload)) > @max_bytes,
        do: {:error, "payload larger than #{@max_bytes} bytes"},
        else: :ok
    end
  end

  defp check_shape(_value, depth) when depth > @max_depth,
    do: {:error, "payload nested deeper than #{@max_depth} levels"}

  defp check_shape(%{} = map, depth) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      if key in @forbidden_keys,
        do: {:halt, {:error, "forbidden key '#{key}'"}},
        else: continue(check_shape(value, depth + 1))
    end)
  end

  defp check_shape(list, depth) when is_list(list),
    do: Enum.reduce_while(list, :ok, fn value, :ok -> continue(check_shape(value, depth + 1)) end)

  defp check_shape(_scalar, _depth), do: :ok

  defp continue(:ok), do: {:cont, :ok}
  defp continue(error), do: {:halt, error}

  @doc """
  The path a `ui/notifications/data-model-change` writes: the key's bound
  path, extended by `subpath` (a JSON pointer or a plain key), or `nil`
  when the key is not bound.

      iex> A2UIPhoenix.MCPApp.change_path(%{"game" => "/game"}, "game", "score")
      "/game/score"
      iex> A2UIPhoenix.MCPApp.change_path(%{"game" => "/game"}, "game", nil)
      "/game"
  """
  @spec change_path(map(), String.t(), String.t() | nil) :: String.t() | nil
  def change_path(paths, key, subpath) do
    case Map.fetch(paths, key) do
      {:ok, path} -> join(path, subpath)
      :error -> nil
    end
  end

  defp join(path, subpath) when subpath in [nil, ""], do: path
  defp join(path, "/" <> _ = subpath), do: String.trim_trailing(path, "/") <> subpath

  defp join(path, subpath) when is_binary(subpath),
    do: String.trim_trailing(path, "/") <> "/" <> subpath

  defp join(_path, _subpath), do: nil
end
