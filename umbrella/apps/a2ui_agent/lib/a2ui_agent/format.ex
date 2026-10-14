defmodule A2UIAgent.Format do
  @moduledoc """
  An inference format: how the model is told to write A2UI, and how its
  output is read back.

  A format module builds a format value from the active catalogs
  (`c:new/2`), renders the system prompt snippet (`c:prompt/1`) and
  creates parsers (`c:parser/1`). A *format spec* names a format module
  and the options it is created with, `{module, options}` (or just the
  module); `create/3` turns a spec into a format for a set of catalogs,
  the way an agent does once per request after negotiating catalogs.

  `A2UIAgent.DirectJson` is the built-in format.
  """

  alias A2UICore.{Catalog, Error}

  @moduledoc since: "0.1.0"

  @typedoc "A format module with its options."
  @type spec :: module() | {module(), keyword()}

  @doc """
  Creates the format for `catalogs` (default catalog first). Options
  include `:examples`, a list of example turns (each a list of
  messages).
  """
  @callback new([Catalog.t()], keyword()) :: {:ok, struct()} | {:error, Error.t()}

  @doc "The system prompt snippet."
  @callback prompt(struct()) :: {:ok, String.t()} | {:error, Error.t()}

  @doc "A fresh parser for the format's catalogs."
  @callback parser(struct()) :: struct()

  @doc """
  Creates the format a spec names for `catalogs`, passing `examples`.
  """
  @spec create(spec(), [Catalog.t()], [[map()]] | nil) :: {:ok, struct()} | {:error, Error.t()}
  def create(module, catalogs, examples) when is_atom(module),
    do: create({module, []}, catalogs, examples)

  def create({module, options}, catalogs, examples) when is_atom(module) and is_list(options),
    do: module.new(catalogs, Keyword.put(options, :examples, examples))
end
