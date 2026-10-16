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

  `A2UIAgent.DirectJson` and `A2UIAgent.Express` are the built-in
  formats.

  A format that implements the optional callbacks `c:catalogs/1`,
  `c:base_rules/1`, `c:catalog_instructions/2` and `c:examples/2` (the
  pieces its prompt is made of) can also be packaged as skills
  (`A2UIAgent.SkillGenerator`).
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

  @doc "The format's active catalogs, in order."
  @callback catalogs(struct()) :: [Catalog.t()]

  @doc "The catalog-independent rules of the prompt."
  @callback base_rules(struct()) :: String.t()

  @doc "The prompt's part for one catalog (by id), or for all of them (`nil`)."
  @callback catalog_instructions(struct(), String.t() | nil) :: String.t()

  @doc "The prompt's examples for one catalog (by id), or for all of them (`nil`)."
  @callback examples(struct(), String.t() | nil) :: {:ok, String.t()} | {:error, Error.t()}

  @optional_callbacks catalogs: 1, base_rules: 1, catalog_instructions: 2, examples: 2

  @doc """
  Creates the format a spec names for `catalogs`, passing `examples`.
  """
  @spec create(spec(), [Catalog.t()], [[map()]] | nil) :: {:ok, struct()} | {:error, Error.t()}
  def create(module, catalogs, examples) when is_atom(module),
    do: create({module, []}, catalogs, examples)

  def create({module, options}, catalogs, examples) when is_atom(module) and is_list(options),
    do: module.new(catalogs, Keyword.put(options, :examples, examples))
end
