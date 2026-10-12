defmodule A2UICore.Validation.Config do
  @moduledoc """
  Options controlling how strictly a component graph and its payloads
  are validated — the reference `ValidationConfig`.

  `strict/0` (the default) requires a `root` component, forbids
  dangling references and unreachable components, and rejects unknown
  elements. `relaxed/0` allows all of those, for streaming or partially
  delivered surfaces.

    * `:root_id` — the entry component, `"root"` by default.
    * `:allow_orphan_components` — components not reachable from the
      root are not an error.
    * `:allow_dangling_references` — references to ids that do not exist
      are not an error.
    * `:allow_missing_root` — a surface without its root component is
      not an error (every component is then a traversal start).
    * `:allow_unknown_elements` — unknown component properties are
      tolerated by schema validation.
    * `:allowed_messages` — when set, only these message action keys are
      accepted.
    * `:max_depth` — logical component-tree depth limit; `nil` means the
      global limit (50).
  """

  @moduledoc since: "0.1.0"

  defstruct root_id: "root",
            allow_orphan_components: false,
            allow_dangling_references: false,
            allow_missing_root: false,
            allow_unknown_elements: false,
            allowed_messages: nil,
            max_depth: nil

  @type t :: %__MODULE__{
          root_id: String.t(),
          allow_orphan_components: boolean(),
          allow_dangling_references: boolean(),
          allow_missing_root: boolean(),
          allow_unknown_elements: boolean(),
          allowed_messages: [String.t()] | nil,
          max_depth: pos_integer() | nil
        }

  @doc """
  The strict preset (every check on).

      iex> A2UICore.Validation.Config.strict().allow_orphan_components
      false
  """
  @spec strict() :: t()
  def strict, do: %__MODULE__{}

  @doc """
  The relaxed preset (orphans, dangling references, a missing root and
  unknown elements are all tolerated).

      iex> A2UICore.Validation.Config.relaxed().allow_missing_root
      true
  """
  @spec relaxed() :: t()
  def relaxed do
    %__MODULE__{
      allow_orphan_components: true,
      allow_dangling_references: true,
      allow_missing_root: true,
      allow_unknown_elements: true
    }
  end

  @doc """
  Builds a config from `options`, starting from the strict preset.

      iex> A2UICore.Validation.Config.new(root_id: "main").root_id
      "main"
  """
  @spec new(keyword()) :: t()
  def new(options \\ []), do: struct!(strict(), options)
end
