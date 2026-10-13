defmodule A2UICore.Message.RendererToAgent do
  @moduledoc """
  Builders for the messages a renderer sends to the agent
  (`renderer_to_agent.json`):

    * `action/2` — a user action on a component;
    * `error/3` — a renderer-side error, about a surface or a function call;
    * `call_agent_function/4` — the renderer asks the agent to run a
      function (v1.0);
    * `function_response/3` — the result of an agent's `callRendererFunction`
      (v1.0).

  Every builder returns the wire map, version included (`:version`,
  `"v1.0"` unless given), ready to be encoded by a transport.

      iex> A2UICore.Message.RendererToAgent.function_response("call-1", {:ok, 42})
      %{
        "version" => "v1.0",
        "rendererFunctionResponse" => %{"functionCallId" => "call-1", "value" => 42}
      }
  """

  @moduledoc since: "0.1.0"

  @default_version "v1.0"

  @doc """
  An `action` message carrying `event`, the map
  `A2UICore.State.Surface.dispatch_action/4` returns.
  """
  @spec action(map(), keyword()) :: map()
  def action(event, options \\ []) when is_map(event),
    do: %{"version" => version(options), "action" => event}

  @doc """
  An `error` message. Options: `:surface_id`, `:function_call_id` and
  `:path`, each included when present, and `:version`.

  The schema requires a validation error (`VALIDATION_FAILED`,
  `UNALLOWED_PARENT`, `UNALLOWED_CHILD`) to carry `surfaceId` and `path`,
  and any other error to carry exactly one of `surfaceId` and
  `functionCallId`.
  """
  @spec error(String.t(), String.t(), keyword()) :: map()
  def error(code, message, options \\ []) when is_binary(code) and is_binary(message) do
    payload =
      %{"code" => code, "message" => message}
      |> put_present("surfaceId", options[:surface_id])
      |> put_present("functionCallId", options[:function_call_id])
      |> put_present("path", options[:path])

    %{"version" => version(options), "error" => payload}
  end

  @doc """
  A `callAgentFunction` message: the renderer asks the agent to run
  `call` (a function call object, `"@call"`/`"catalogId"`/`"args"`).
  """
  @spec call_agent_function(String.t(), String.t(), map(), keyword()) :: map()
  def call_agent_function(surface_id, function_call_id, call, options \\ [])
      when is_binary(surface_id) and is_binary(function_call_id) and is_map(call) do
    %{
      "version" => version(options),
      "callAgentFunction" => %{
        "surfaceId" => surface_id,
        "functionCallId" => function_call_id,
        "callFunction" => call
      }
    }
  end

  @doc """
  A `rendererFunctionResponse` message: `{:ok, value}` for a result
  (`value` is always present, `nil` for a void function) or
  `{:error, code, message}`.
  """
  @spec function_response(String.t(), {:ok, term()} | {:error, String.t(), String.t()}, keyword()) ::
          map()
  def function_response(function_call_id, outcome, options \\ [])
      when is_binary(function_call_id) do
    response =
      case outcome do
        {:ok, value} ->
          %{"functionCallId" => function_call_id, "value" => value}

        {:error, code, message} ->
          %{
            "functionCallId" => function_call_id,
            "error" => %{"code" => code, "message" => message}
          }
      end

    %{"version" => version(options), "rendererFunctionResponse" => response}
  end

  defp version(options), do: Keyword.get(options, :version, @default_version)

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
