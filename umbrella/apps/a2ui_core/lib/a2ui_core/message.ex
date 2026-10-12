defmodule A2UICore.Message do
  @moduledoc """
  Wire messages: decode raw agent→renderer payloads into canonical
  `A2UICore.Message.Operation` structs, and encode operations back to
  wire-format maps.

  `decode/2` accepts everything the transport contract allows — a
  single message map, a bare JSON array of messages, a
  `{"messages": [...]}` wrapper, or `nil` (no-op):

      {:ok, ops} = A2UICore.Message.decode(payload)

  Decoding runs the full reference pipeline: payload sniffing
  (`A2UICore.Message.AdapterRegistry`), recursion/pointer preflight
  (`A2UICore.Validation.Integrity`), per-version envelope validation
  against the vendored spec schemas with the active catalog bound to
  the `catalog.json` placeholder, and canonical operation extraction
  (`A2UICore.Message.Adapter`).

  ## Options

    * `:catalog` — the active catalog schema map for component
      validation (defaults to the shipped basic catalog of the
      message's protocol version).

  ## Examples

      iex> {:ok, [%A2UICore.Message.Operation.UpdateDataModel{} = op]} =
      ...>   A2UICore.Message.decode(%{
      ...>     "version" => "v1.0",
      ...>     "updateDataModel" => %{"surfaceId" => "main", "value" => %{"user" => "Ada"}}
      ...>   })
      iex> {op.path, op.value}
      {"/", %{"user" => "Ada"}}
  """

  alias A2UICore.Error
  alias A2UICore.Message.{Adapter, AdapterRegistry, Encode, Operation}

  @moduledoc since: "0.1.0"

  @typedoc "Decode options (see module docs)."
  @type opts :: keyword()

  @doc """
  Decodes a raw payload into canonical operations.

  Returns `{:ok, operations}` or `{:error, %A2UICore.Error{}}` (always
  category `:validation` for wire problems).

  `nil` is a no-op (`{:ok, []}`) — matching the TypeScript processor
  and the reference adapter's own tolerance. (The Python factory
  rejects `nil` instead; we choose the lenient behaviour, and the
  registry retains the strict one for direct callers.)
  """
  @spec decode(term(), opts()) :: {:ok, [Operation.t()]} | {:error, Error.t()}
  def decode(payload, opts \\ [])

  def decode(nil, _opts), do: {:ok, []}

  def decode(payload, opts) do
    with {:ok, adapter} <- AdapterRegistry.resolve_from_payload(payload) do
      Adapter.extract(adapter, payload, opts)
    end
  end

  @doc """
  Like `decode/2`, raising `A2UICore.Error` on failure.
  """
  @spec decode!(term(), opts()) :: [Operation.t()]
  def decode!(payload, opts \\ []) do
    case decode(payload, opts) do
      {:ok, ops} -> ops
      {:error, error} -> raise error
    end
  end

  @doc """
  Encodes canonical operations back into wire-format message maps.

  `overrides` may pass `:version` to force a wire version (e.g.
  `"v0.9.1"` instead of `"v0.9"`).
  """
  @spec encode(Operation.t() | [Operation.t()], keyword()) :: map() | [map()]
  def encode(ops, overrides \\ [])

  def encode([_ | _] = ops, overrides), do: Encode.to_maps(ops, overrides)
  def encode([], _overrides), do: []
  def encode(op, overrides) when is_struct(op), do: Encode.to_map(op, overrides)
end
