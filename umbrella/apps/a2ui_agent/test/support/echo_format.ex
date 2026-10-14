defmodule A2UIAgent.Test.EchoFormat do
  @moduledoc false
  # A format whose prompt and parses echo what it was created with.

  @behaviour A2UIAgent.Format

  defstruct [:catalogs, :options]

  @impl true
  def new(catalogs, options), do: {:ok, %__MODULE__{catalogs: catalogs, options: options}}

  @impl true
  def prompt(%__MODULE__{options: options}), do: {:ok, "echo #{inspect(options)}"}

  @impl true
  def parser(%__MODULE__{} = format), do: format

  def parse_response(%__MODULE__{}, content, options), do: {:ok, [{:echo, content, options}]}
end
