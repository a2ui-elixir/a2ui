defmodule A2UIPhoenix.Live do
  @moduledoc """
  Hosts an `A2UIPhoenix.Session` in a LiveView.

      def mount(_params, _session, socket) do
        session = A2UIPhoenix.Session.new([A2UICore.Catalog.Basic.catalog("v1.0")])
        {:ok, A2UIPhoenix.Live.init(socket, session, on_send: &send_to_agent/2)}
      end

      def handle_info({:agent, payload}, socket) do
        {_result, socket} = A2UIPhoenix.Live.handle_message(socket, payload)
        {:noreply, socket}
      end

  and render each surface with `A2UIPhoenix.Surface`:

  ```heex
  <.live_component
    :for={surface <- A2UIPhoenix.Session.surfaces(@a2ui)}
    module={A2UIPhoenix.Surface}
    id={"surface-" <> surface.id}
    session={@a2ui}
    surface_id={surface.id}
  />
  ```

  `init/3` assigns the session and attaches a `handle_info` hook that
  applies the writes and actions the surfaces report, so the host does not
  handle those messages itself.

  Effects are delivered as they happen:

    * `{:send, message}` goes to the `:on_send` callback — the host's
      transport to the agent;
    * `{:open_url, url}` is pushed to the browser as the `"a2ui:open_url"`
      event (`priv/static/a2ui_phoenix.js` opens it in a new tab);
    * `{:agent_call_sent, call_id, timeout_ms}` starts the call's timer,
      which rejects the call with `TIMEOUT` if the agent has not answered
      when it fires (`A2UIPhoenix.Session.timeout_agent_call/2`), and also
      goes to the `:on_effect` callback;
    * every other effect goes to the `:on_effect` callback.

  The reply to an embedded MCP App's request is pushed as the
  `"a2ui:mcp_app:reply"` event, which the `A2UIMcpApp` hook relays to the
  app.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, push_event: 3, put_private: 3]

  alias A2UICore.Error
  alias A2UIPhoenix.Session
  alias Phoenix.LiveView.Socket

  @moduledoc since: "0.1.0"

  @type callback :: (term(), Socket.t() -> Socket.t())

  @doc """
  Assigns `session` and attaches the hook.

  Options:

    * `:assign` — the assign holding the session (`:a2ui`);
    * `:on_send` — `(message, socket -> socket)`, called for each
      renderer→agent message;
    * `:on_effect` — `(effect, socket -> socket)`, called for the other
      session effects.
  """
  @spec init(Socket.t(), Session.t(), keyword()) :: Socket.t()
  def init(%Socket{} = socket, %Session{} = session, options \\ []) do
    config = %{
      assign: Keyword.get(options, :assign, :a2ui),
      on_send: options[:on_send],
      on_effect: options[:on_effect]
    }

    socket
    |> put_private(:a2ui, config)
    |> assign(config.assign, session)
    |> attach_hook(:a2ui, :handle_info, &handle_info/2)
  end

  @doc "The session `init/3` assigned."
  @spec session(Socket.t()) :: Session.t()
  def session(%Socket{} = socket), do: socket.assigns[config(socket).assign]

  @doc """
  Applies an agent payload to the session (`A2UIPhoenix.Session.handle_message/3`)
  and delivers the effects. Returns `:ok` or `{:error, error}` with the
  updated socket: a failed message may still have changed some surfaces,
  and its `error` report has been sent.
  """
  @spec handle_message(Socket.t(), term(), keyword()) ::
          {:ok | {:error, Error.t()}, Socket.t()}
  def handle_message(%Socket{} = socket, payload, options \\ []) do
    case Session.handle_message(session(socket), payload, options) do
      {:ok, session, effects} -> {:ok, commit(socket, session, effects)}
      {:error, error, session, effects} -> {{:error, error}, commit(socket, session, effects)}
    end
  end

  defp handle_info({A2UIPhoenix.Surface, surface_id, request}, socket),
    do: {:halt, apply_request(socket, surface_id, request)}

  defp handle_info({__MODULE__, :agent_call_timeout, call_id}, socket),
    do: {:halt, apply_result(socket, Session.timeout_agent_call(session(socket), call_id))}

  defp handle_info(_message, socket), do: {:cont, socket}

  defp apply_request(socket, surface_id, {:write, ref, property, value}),
    do: apply_result(socket, Session.write(session(socket), surface_id, ref, property, value))

  defp apply_request(socket, surface_id, {:invoke, ref, property}),
    do: apply_result(socket, Session.invoke(session(socket), surface_id, ref, property))

  defp apply_request(socket, surface_id, {:mcp_app, ref, method, params, id}) do
    case Session.mcp_app_request(session(socket), surface_id, ref, method, params) do
      {:ok, session, effects, reply} ->
        socket |> commit(session, effects) |> reply(surface_id, ref, id, reply)

      {:error, %Error{}} ->
        socket
    end
  end

  defp reply(socket, _surface_id, _ref, nil, _reply), do: socket
  defp reply(socket, _surface_id, _ref, _id, :none), do: socket

  defp reply(socket, surface_id, ref, id, {:result, result}),
    do: push_reply(socket, %{surface_id: surface_id, ref: ref, id: id, result: result})

  defp reply(socket, surface_id, ref, id, {:error, code, message}) do
    error = %{code: code, message: message}
    push_reply(socket, %{surface_id: surface_id, ref: ref, id: id, error: error})
  end

  defp push_reply(socket, payload), do: push_event(socket, "a2ui:mcp_app:reply", payload)

  # A request about a node that went away in the meantime is dropped.
  defp apply_result(socket, {:ok, session, effects}), do: commit(socket, session, effects)
  defp apply_result(socket, {:error, %Error{}}), do: socket

  defp commit(socket, session, effects) do
    socket = assign(socket, config(socket).assign, session)
    Enum.reduce(effects, socket, &deliver/2)
  end

  defp deliver({:send, message}, socket), do: callback(socket, :on_send, message)
  defp deliver({:open_url, url}, socket), do: push_event(socket, "a2ui:open_url", %{url: url})

  defp deliver({:agent_call_sent, call_id, timeout_ms} = effect, socket) do
    if is_number(timeout_ms) and timeout_ms > 0,
      do:
        Process.send_after(self(), {__MODULE__, :agent_call_timeout, call_id}, round(timeout_ms))

    callback(socket, :on_effect, effect)
  end

  defp deliver(effect, socket), do: callback(socket, :on_effect, effect)

  defp callback(socket, key, value) do
    case Map.fetch!(config(socket), key) do
      nil -> socket
      fun -> fun.(value, socket)
    end
  end

  defp config(%Socket{private: %{a2ui: config}}), do: config

  defp config(%Socket{}),
    do: raise(ArgumentError, "A2UIPhoenix.Live.init/3 was not called on this socket")
end
