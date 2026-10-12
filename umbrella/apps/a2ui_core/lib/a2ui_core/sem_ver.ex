defmodule A2UICore.SemVer do
  @moduledoc """
  Semantic Versioning 2.0.0 parsing and comparison.

  Mirrors `a2ui-core`'s `common/semver.py` semantics (upstream reference),
  extended with Elixir-idiomatic `{:ok, _}`/`:error` returns and tuples.

  ## Normalization

  * `v1_0` / `V1_0` / `1.0` / `1.0.0` / `v1_0_0` are all equivalent to
    each other and normalize to `1.0` (patch omitted when `0`).
  * Pre-release (`-beta.1`) and build (`+meta`) suffixes survive the
    normalization and are included in the canonical form when present.

  ## Comparison

  Full SemVer 2.0.0 precedence rules:
  `1.0.0-alpha < 1.0.0-alpha.1 < 1.0.0-alpha.beta < 1.0.0-beta <
  1.0.0-beta.2 < 1.0.0-beta.11 < 1.0.0-rc.1 < 1.0.0`. Build metadata is
  ignored.
  """

  @moduledoc since: "0.1.0"

  @type t :: %__MODULE__{
          major: non_neg_integer(),
          minor: non_neg_integer(),
          patch: non_neg_integer(),
          prerelease: [String.t()],
          build: [String.t()]
        }

  defstruct major: 0,
            minor: 0,
            patch: 0,
            prerelease: [],
            build: []

  @semver_regex Regex.compile!(
                  ~S"^[vV]?(0|[1-9]\d*)\.(0|[1-9]\d*)(?:\.(0|[1-9]\d*))?(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$",
                  [:unicode]
                )

  @doc """
  Strips a leading `v`/`V` and replaces underscores in the release core
  with dots, preserving any `-prerelease`/`+build` tail. `"v1_0"` →
  `"1.0"`.
  """
  @spec normalize(term()) :: String.t()
  def normalize(version) when not is_binary(version), do: ""

  def normalize(version) do
    text = String.trim(version)

    text =
      case text do
        <<lead::binary-size(1), rest::binary>> when lead in ["v", "V"] -> rest
        _ -> text
      end

    split_idx =
      [String.split(text, "-", parts: 2), String.split(text, "+", parts: 2)]
      |> Enum.map(fn parts ->
        if length(parts) == 2, do: String.length(hd(parts)), else: String.length(text)
      end)
      |> Enum.min()

    core = String.slice(text, 0, split_idx) |> String.replace("_", ".")
    core <> String.slice(text, split_idx..-1//1)
  end

  @doc """
  Parses a version string as SemVer 2.0.0. Returns `{:ok, version}` or
  `:error`.

  ## Examples

      iex> {:ok, v} = A2UICore.SemVer.parse("v1.0")
      iex> {v.major, v.minor, v.patch}
      {1, 0, 0}
      iex> A2UICore.SemVer.parse("not_a_version")
      :error

      iex> A2UICore.SemVer.parse("1")
      :error
  """
  @spec parse(term()) :: {:ok, t()} | :error
  def parse(version) when not is_binary(version), do: :error

  def parse(version) do
    case Regex.run(@semver_regex, String.trim(version)) do
      [_ | _] = parts ->
        captures = tl(parts)

        [major, minor, patch, prerelease, build] =
          captures ++ List.duplicate("", 5 - length(captures))

        {:ok,
         to_version(
           parse_int(major),
           parse_int(minor),
           parse_patch(patch),
           parse_identifiers(prerelease),
           parse_identifiers(build)
         )}

      _ ->
        :error
    end
  end

  @spec to_version(non_neg_integer(), non_neg_integer(), non_neg_integer(), [String.t()], [
          String.t()
        ]) :: t()
  defp to_version(major, minor, patch, pre, build) do
    %__MODULE__{major: major, minor: minor, patch: patch, prerelease: pre, build: build}
  end

  @spec parse_int(String.t()) :: non_neg_integer()
  defp parse_int(text), do: String.to_integer(text)

  @spec parse_patch(String.t()) :: non_neg_integer()
  defp parse_patch(""), do: 0
  defp parse_patch(text), do: String.to_integer(text)

  @spec parse_identifiers(String.t() | nil) :: [String.t()]
  defp parse_identifiers(nil), do: []
  defp parse_identifiers(""), do: []
  defp parse_identifiers(text), do: String.split(text, ".")

  @doc """
  A shorthand for `parse/1` that also accepts an already-parsed
  `t:A2UICore.SemVer.t/0`.

  Returns `{:ok, t}` or `:error`.
  """
  @spec to_semver(t() | String.t() | nil) :: {:ok, t()} | :error
  def to_semver(%__MODULE__{} = v), do: {:ok, v}

  def to_semver(v) do
    case normalize(v) do
      "" -> :error
      normalized -> parse(normalized)
    end
  end

  @doc """
  Canonical text form per upstream rule: `major.minor` when patch is `0`
  and no prerelease/build, otherwise full `major.minor.patch[-pre][+build]`.

  Semantics copied from upstream `to_canonical_version/1`: input that is not
  parseable returns `nil`.
  """
  @spec to_canonical(t() | String.t() | nil) :: String.t() | nil
  def to_canonical(version) do
    case to_semver(version) do
      :error ->
        nil

      {:ok, %{patch: 0, prerelease: [], build: []} = v} ->
        "#{v.major}.#{v.minor}"

      {:ok, v} ->
        to_string(v)
    end
  end

  @doc """
  Compares two versions per SemVer 2.0.0 section 11 precedence rules.

  Returns a negative integer, zero, or a positive integer for
  `<`, `==`, `>` relationships. `nil` or unparseable compares as
  smaller than anything that parses.
  """
  @spec compare(t() | String.t() | nil, t() | String.t() | nil) :: integer()
  def compare(a, b) do
    {va, vb} = {to_semver(a), to_semver(b)}

    cond do
      va == :error and vb == :error -> 0
      va == :error -> -1
      vb == :error -> 1
      true -> compare_parsed(elem(va, 1), elem(vb, 1))
    end
  end

  @spec compare_parsed(t(), t()) :: integer()
  defp compare_parsed(a, b) do
    cond do
      a.major != b.major -> a.major - b.major
      a.minor != b.minor -> a.minor - b.minor
      a.patch != b.patch -> a.patch - b.patch
      true -> compare_prerelease_list(a.prerelease, b.prerelease)
    end
  end

  @spec compare_prerelease_list([String.t()], [String.t()]) :: integer()
  defp compare_prerelease_list([], []), do: 0
  # Rule 11.3: a version with a prerelease has lower precedence than the release.
  defp compare_prerelease_list([], [_ | _]), do: 1
  defp compare_prerelease_list([_ | _], []), do: -1
  defp compare_prerelease_list(a, b), do: compare_prerelease_pairs(a, b)

  @spec compare_prerelease_pairs([String.t()], [String.t()]) :: integer()
  defp compare_prerelease_pairs([a | as_], [b | bs]) do
    case compare_prerelease_id(a, b) do
      0 -> compare_prerelease_pairs(as_, bs)
      other -> other
    end
  end

  # Rule 11.4.4: after an equal prefix, the longer set has higher precedence.
  defp compare_prerelease_pairs([], []), do: 0
  defp compare_prerelease_pairs([], [_ | _]), do: -1
  defp compare_prerelease_pairs([_ | _], []), do: 1

  @spec compare_prerelease_id(String.t(), String.t()) :: integer()
  defp compare_prerelease_id(a, b) do
    {num_a?, num_b?} = {numeric?(a), numeric?(b)}

    cond do
      num_a? and num_b? -> String.to_integer(a) - String.to_integer(b)
      num_a? -> -1
      num_b? -> 1
      a < b -> -1
      a > b -> 1
      true -> 0
    end
  end

  @spec numeric?(String.t()) :: boolean()
  defp numeric?(id), do: Regex.match?(~r/^[0-9]+$/u, id)

  @doc """
  Whether `version` is parseable and at least `minimum` (both may be
  `t:A2UICore.SemVer.t/0` or strings).

  ## Examples

      iex> A2UICore.SemVer.at_least("v1.0", "v0.9")
      true
      iex> A2UICore.SemVer.at_least(nil, "v1.0")
      false
  """
  @spec at_least(t() | String.t() | nil, t() | String.t()) :: boolean()
  def at_least(version, min_version) do
    case {to_semver(version), to_semver(min_version)} do
      {{:ok, v}, {:ok, m}} -> compare(v, m) >= 0
      _ -> false
    end
  end

  defimpl String.Chars do
    def to_string(%{patch: 0, prerelease: [], build: []} = v), do: "#{v.major}.#{v.minor}"

    def to_string(v) do
      pre = if Enum.empty?(v.prerelease), do: "", else: "-#{Enum.join(v.prerelease, ".")}"
      bld = if Enum.empty?(v.build), do: "", else: "+#{Enum.join(v.build, ".")}"
      "#{v.major}.#{v.minor}.#{v.patch}#{pre}#{bld}"
    end
  end
end
