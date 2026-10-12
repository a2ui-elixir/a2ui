defmodule A2UICore.Validation.ReservedKeys do
  @moduledoc """
  The v1.0 reserved-key rule for dynamic objects.

  In v1.0 a key that starts with a single `@` is a protocol directive
  (`@path`, `@call`). Any other `@`-prefixed key must be escaped by
  doubling the prefix (`@@note` stands for the literal key `@note`);
  `unescape/1` undoes that when a value is resolved.
  """

  alias A2UICore.Error
  alias A2UICore.Error.Detail
  alias A2UICore.SemVer

  @moduledoc since: "0.1.0"

  @directives ["@call", "@path"]

  @doc """
  Whether `key` starts with a single `@` (not the escaped `@@`).

      iex> A2UICore.Validation.ReservedKeys.directive_like?("@path")
      true
      iex> A2UICore.Validation.ReservedKeys.directive_like?("@@path")
      false
  """
  @spec directive_like?(String.t()) :: boolean()
  def directive_like?(key),
    do: String.starts_with?(key, "@") and not String.starts_with?(key, "@@")

  @doc """
  Removes one `@` from an escaped key (`"@@path"` → `"@path"`).
  """
  @spec unescape(String.t()) :: String.t()
  def unescape("@@" <> rest), do: "@" <> rest
  def unescape(key), do: key

  @doc """
  Checks that every single-`@` key of a dynamic object is a known
  directive. Protocol versions before v1.0 have no reserved keys.
  """
  @spec check([String.t()], String.t() | nil) :: :ok | {:error, Error.t()}
  def check(keys, version) do
    if is_binary(version) and SemVer.at_least(version, "v1.0") do
      keys
      |> Enum.sort()
      |> Enum.find(&(directive_like?(&1) and &1 not in @directives))
      |> case do
        nil -> :ok
        key -> {:error, unrecognized(key)}
      end
    else
      :ok
    end
  end

  defp unrecognized(key) do
    message =
      "Unrecognized reserved protocol directive '#{key}' in v1.0 dynamic object. " <>
        "Reserved keys must be in #{Enum.join(@directives, ", ")}, or escaped with prefix " <>
        "doubling (e.g. '@#{key}')."

    Error.new(:validation, "INVALID_RESERVED_KEY", message,
      details: [Detail.new("INVALID_RESERVED_KEY", message, "")]
    )
  end
end
