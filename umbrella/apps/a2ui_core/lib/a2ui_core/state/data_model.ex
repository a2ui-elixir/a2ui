defmodule A2UICore.State.DataModel do
  @moduledoc """
  The reactive JSON data store behind a surface — an immutable port of
  the reference `DataModel` (RFC 6901 pointers, auto-vivifying writes,
  cascading change notifications).

  The model is plain data: every write returns the new model together
  with the notifications it caused, and the caller (a surface, a
  LiveView, a test) decides how to deliver them. There are no processes
  and no callbacks.

  ## Reads

  `get/2` returns `{:ok, value}`, with `nil` for an absent path — an
  absent path and an explicit `null` are indistinguishable there;
  `has_path?/2` tells them apart. Paths follow `A2UICore.Pointer`:
  empty segments are dropped (`"//a///b//"` is `"/a/b"`), `~1` and `~0`
  unescape in that order, and `__proto__`, `constructor` and `prototype`
  are rejected on read and write with a `:data` error. List elements
  address by RFC 6901 numeric segments (`"01"` is not an index).

  ## Writes

  `set/3` writes a value at a path, creating missing containers on the
  way: a list when the next segment is numeric, an object otherwise.
  Lists are padded with `nil` up to the written index (at most
  #{10_000}). Writing `nil` deletes: an object key is removed, a list
  slot becomes `nil` (the list keeps its length), and deleting a path
  that does not exist is a no-op. Writing `nil` at the root resets the
  model to `%{}`. A primitive root, or a primitive in the middle of a
  path, cannot be written through.

  Writes are **atomic**: on error the original model is untouched. (The
  reference leaves partial writes behind; see `NOTES/divergences.md`.)

  ## Subscriptions and notifications

  `subscribe/2` registers interest in a path and returns an id plus the
  current value. A write notifies every subscription whose path equals,
  contains, or lies under the written path — compared segment by
  segment, so `/foo` is not under `/foobar` — and only when the value
  at the subscribed path actually changed. A notification is
  `{subscription_id, normalized_path, new_value}`, ordered by
  subscription id.

      iex> model = A2UICore.State.DataModel.new(%{"user" => %{"name" => "Ada"}})
      iex> {:ok, model, id, "Ada"} = A2UICore.State.DataModel.subscribe(model, "/user/name")
      iex> {:ok, model, [{^id, "/user/name", "Grace"}]} =
      ...>   A2UICore.State.DataModel.set(model, "/user/name", "Grace")
      iex> A2UICore.State.DataModel.get(model, "/user")
      {:ok, %{"name" => "Grace"}}
  """

  alias A2UICore.Error
  alias A2UICore.Pointer

  @moduledoc since: "0.1.0"

  defstruct data: %{}, subscriptions: [], next_id: 1

  @typedoc "A data model."
  @type t :: %__MODULE__{
          data: term(),
          subscriptions: [%{id: pos_integer(), path: String.t(), tokens: [String.t()]}],
          next_id: pos_integer()
        }

  @typedoc "Identifies one subscription for `unsubscribe/2` and notifications."
  @type subscription_id :: pos_integer()

  @typedoc "A change notification: subscription, its normalized path, the new value."
  @type notification :: {subscription_id(), String.t(), term()}

  # ------------------------------------------------------------------ build --

  @doc """
  Creates a model holding `initial` (`nil` means an empty object).
  """
  @spec new(term()) :: t()
  def new(initial \\ nil), do: %__MODULE__{data: if(is_nil(initial), do: %{}, else: initial)}

  @doc """
  The whole value held by the model (what `get(model, "/")` returns).
  """
  @spec data(t()) :: term()
  def data(%__MODULE__{data: data}), do: data

  # ------------------------------------------------------------------ reads --

  @doc """
  Reads the value at `path`; `{:ok, nil}` when nothing is there.

  Returns `{:error, error}` (category `:data`) for a path that is not a
  string or contains a forbidden segment.
  """
  @spec get(t(), term()) :: {:ok, term()} | {:error, Error.t()}
  def get(%__MODULE__{data: data}, path) do
    with {:ok, tokens} <- Pointer.parse(path), do: {:ok, value_at(data, tokens)}
  end

  @doc """
  Like `get/2`, raising `A2UICore.Error` on a bad path.
  """
  @spec get!(t(), term()) :: term()
  def get!(%__MODULE__{} = model, path) do
    case get(model, path) do
      {:ok, value} -> value
      {:error, error} -> raise error
    end
  end

  @doc """
  Whether `path` physically exists — distinguishes an explicit `null`
  from a missing key. The root always exists.
  """
  @spec has_path?(t(), term()) :: {:ok, boolean()} | {:error, Error.t()}
  def has_path?(%__MODULE__{data: data}, path) do
    with {:ok, tokens} <- Pointer.parse(path), do: {:ok, lookup(data, tokens) != :error}
  end

  # ----------------------------------------------------------------- writes --

  @doc """
  Writes `value` at `path` (`nil` deletes). Returns the new model and
  the notifications the write caused, or an error leaving the model
  untouched.
  """
  @spec set(t(), term(), term()) :: {:ok, t(), [notification()]} | {:error, Error.t()}
  def set(%__MODULE__{} = model, path, value) do
    with {:ok, tokens} <- Pointer.parse(path),
         {:ok, new_data} <- write(model.data, tokens, value, path) do
      new_model = %{model | data: new_data}
      {:ok, new_model, notifications(model, new_model, tokens)}
    end
  end

  @doc """
  Deletes the value at `path`; shorthand for `set(model, path, nil)`.
  """
  @spec delete(t(), term()) :: {:ok, t(), [notification()]} | {:error, Error.t()}
  def delete(%__MODULE__{} = model, path), do: set(model, path, nil)

  # Deleting something that is not there is a no-op, even through a
  # primitive (the reference checks existence before any structural
  # error). The root always exists, so `nil` there resets the model.
  defp write(data, tokens, nil, path) when tokens != [] do
    case lookup(data, tokens) do
      :error -> {:ok, data}
      {:ok, _} -> do_write(data, tokens, nil, path)
    end
  end

  defp write(data, tokens, value, path), do: do_write(data, tokens, value, path)

  defp do_write(_data, [], nil, _path), do: {:ok, %{}}
  defp do_write(_data, [], value, _path), do: {:ok, value}

  defp do_write(data, tokens, value, path) when is_map(data) or is_list(data),
    do: put(data, tokens, value, path)

  defp do_write(nil, tokens, value, path), do: put(%{}, tokens, value, path)

  defp do_write(_primitive, _tokens, _value, path),
    do: data_error(path, "Cannot set path '#{path}': the data model root is a primitive value.")

  # Leaf.
  defp put(map, [token], value, _path) when is_map(map) do
    if is_nil(value), do: {:ok, Map.delete(map, token)}, else: {:ok, Map.put(map, token, value)}
  end

  defp put(list, [token], value, path) when is_list(list) do
    with {:ok, index} <- list_index(token, path) do
      # Deleting past the end must not materialise entries.
      if is_nil(value) and index >= length(list),
        do: {:ok, list},
        else: {:ok, list |> pad(index) |> List.replace_at(index, value)}
    end
  end

  # Intermediate: descend, vivifying a missing (or null) child.
  defp put(map, [token, next | _] = tokens, value, path) when is_map(map) do
    with {:ok, child} <- container(Map.get(map, token), token, next, path),
         {:ok, updated} <- put(child, tl(tokens), value, path) do
      {:ok, Map.put(map, token, updated)}
    end
  end

  defp put(list, [token, next | _] = tokens, value, path) when is_list(list) do
    with {:ok, index} <- list_index(token, path),
         padded = pad(list, index),
         {:ok, child} <- container(Enum.at(padded, index), token, next, path),
         {:ok, updated} <- put(child, tl(tokens), value, path) do
      {:ok, List.replace_at(padded, index, updated)}
    end
  end

  defp container(nil, _token, next, _path), do: {:ok, if(numeric?(next), do: [], else: %{})}

  defp container(child, _token, _next, _path) when is_map(child) or is_list(child),
    do: {:ok, child}

  defp container(_primitive, token, _next, path),
    do: data_error(path, "Cannot set path '#{path}': segment '#{token}' is a primitive value.")

  defp list_index(token, path) do
    cond do
      !numeric?(token) ->
        data_error(
          path,
          "Cannot use non-numeric segment '#{token}' on an array in path '#{path}'."
        )

      String.to_integer(token) > Pointer.max_array_index() ->
        data_error(
          path,
          "Cannot set path '#{path}': array index '#{token}' exceeds maximum supported " <>
            "index (#{Pointer.max_array_index()})."
        )

      true ->
        {:ok, String.to_integer(token)}
    end
  end

  defp pad(list, index) do
    missing = index + 1 - length(list)
    if missing > 0, do: list ++ List.duplicate(nil, missing), else: list
  end

  defp numeric?(token), do: Pointer.array_index?(token)

  defp data_error(path, message),
    do: {:error, Error.new(:data, "DATA_ERROR", message, path: path)}

  # ---------------------------------------------------------------- lookups --

  @spec lookup(term(), [String.t()]) :: {:ok, term()} | :error
  defp lookup(value, []), do: {:ok, value}

  defp lookup(map, [token | rest]) when is_map(map) do
    case Map.fetch(map, token) do
      {:ok, child} -> lookup(child, rest)
      :error -> :error
    end
  end

  defp lookup(list, [token | rest]) when is_list(list) do
    with true <- numeric?(token),
         index = String.to_integer(token),
         true <- index < length(list) do
      lookup(Enum.at(list, index), rest)
    else
      _ -> :error
    end
  end

  defp lookup(_primitive, _tokens), do: :error

  defp value_at(data, tokens) do
    case lookup(data, tokens) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  # ---------------------------------------------------------- subscriptions --

  @doc """
  Subscribes to `path`. Returns the new model, the subscription id and
  the value currently at the path.
  """
  @spec subscribe(t(), term()) ::
          {:ok, t(), subscription_id(), term()} | {:error, Error.t()}
  def subscribe(%__MODULE__{} = model, path) do
    with {:ok, tokens} <- Pointer.parse(path) do
      id = model.next_id
      subscription = %{id: id, path: Pointer.build(tokens), tokens: tokens}

      {:ok, %{model | subscriptions: model.subscriptions ++ [subscription], next_id: id + 1}, id,
       value_at(model.data, tokens)}
    end
  end

  @doc """
  Removes a subscription (unknown ids are ignored).
  """
  @spec unsubscribe(t(), subscription_id()) :: t()
  def unsubscribe(%__MODULE__{} = model, id),
    do: %{model | subscriptions: Enum.reject(model.subscriptions, &(&1.id == id))}

  @doc """
  Detaches every subscription. The data is kept.
  """
  @spec dispose(t()) :: t()
  def dispose(%__MODULE__{} = model), do: %{model | subscriptions: []}

  @doc """
  The subscribed paths, as `{id, normalized_path}` pairs.
  """
  @spec subscriptions(t()) :: [{subscription_id(), String.t()}]
  def subscriptions(%__MODULE__{subscriptions: subscriptions}),
    do: Enum.map(subscriptions, &{&1.id, &1.path})

  # A subscription is relevant to a write when its path equals, contains
  # or lies under the written path; it fires only if its value changed.
  defp notifications(old, new, written) do
    Enum.flat_map(new.subscriptions, fn %{id: id, path: path, tokens: tokens} ->
      old_value = value_at(old.data, tokens)
      new_value = value_at(new.data, tokens)

      if relevant?(tokens, written) and old_value != new_value,
        do: [{id, path, new_value}],
        else: []
    end)
  end

  defp relevant?(subscribed, written),
    do: List.starts_with?(subscribed, written) or List.starts_with?(written, subscribed)
end
