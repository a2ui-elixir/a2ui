defmodule A2UICore.Resolution.Action do
  @moduledoc """
  An action property of a resolved component.

  The definition is kept as the component declared it. Its dynamic
  parts (an event's `context`, a function call's arguments) are
  evaluated when the action is invoked, against the data model as it is
  then — see `A2UICore.Resolution.NodeResolver.invoke/4`.
  """

  @moduledoc since: "0.1.0"

  @enforce_keys [:definition]
  defstruct [:definition]

  @type t :: %__MODULE__{definition: term()}
end
