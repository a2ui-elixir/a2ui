defmodule A2UIAgent.Builder.Component do
  @moduledoc """
  A component node of an `A2UIAgent.Builder` tree: the component name,
  the id the author gave (if any) and the properties, as wire names and
  values in the order given. Made by `A2UIAgent.Builder.component/2`.
  """

  @moduledoc since: "0.1.0"

  @enforce_keys [:component]
  defstruct [:component, :id, props: []]

  @type t :: %__MODULE__{
          component: String.t(),
          id: String.t() | nil,
          props: [{String.t(), term()}]
        }
end

defmodule A2UIAgent.Builder.Ref do
  @moduledoc """
  A reference to a component already on the surface. It is written as
  its id and never emitted. Made by `A2UIAgent.Builder.ref/1`.
  """

  @moduledoc since: "0.1.0"

  @enforce_keys [:id]
  defstruct [:id]

  @type t :: %__MODULE__{id: String.t()}
end

defmodule A2UIAgent.Builder.Binding do
  @moduledoc """
  A data binding, written as `{"path": path}` (`{"@path": path}` from
  v1.0). Made by `A2UIAgent.Builder.bind/1`.
  """

  @moduledoc since: "0.1.0"

  @enforce_keys [:path]
  defstruct [:path]

  @type t :: %__MODULE__{path: String.t()}
end

defmodule A2UIAgent.Builder.ChildList do
  @moduledoc """
  Children generated from a data model list: the list's path and the
  template component repeated for each item, written as
  `{"path": path, "componentId": template_id}`. Made by
  `A2UIAgent.Builder.child_list/2`.
  """

  @moduledoc since: "0.1.0"

  @enforce_keys [:path, :template]
  defstruct [:path, :template]

  @type t :: %__MODULE__{
          path: String.t(),
          template: A2UIAgent.Builder.Component.t() | A2UIAgent.Builder.Ref.t()
        }
end

defmodule A2UIAgent.Builder.FunctionCall do
  @moduledoc """
  A call of a catalog function, written as `{"call": name, "args": args}`
  (`"@call"` from v1.0). Made by `A2UIAgent.Builder.call/3`.
  """

  @moduledoc since: "0.1.0"

  @enforce_keys [:call]
  defstruct [:call, :return_type, args: %{}]

  @type t :: %__MODULE__{
          call: String.t(),
          args: %{optional(String.t()) => term()},
          return_type: String.t() | nil
        }
end
