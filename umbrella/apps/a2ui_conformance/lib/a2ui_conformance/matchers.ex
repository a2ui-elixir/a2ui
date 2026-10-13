defmodule A2UIConformance.Matchers do
  @moduledoc false

  # Assertion helpers that mirror the reference Python harness exactly:
  #
  # * `assert_error/2` ports `assert_raises`: expected category (with the
  #   reference's category→exception aliasing), message matching
  #   (case-sensitive substring → per-detail substring → escaped-regex →
  #   raw-regex → the lowercase fuzzy synonym table), and the top-level
  #   `code` check (present in detail codes, the error code, or the
  #   message). One deliberate deviation, documented: the searchable
  #   string also includes detail *codes* so "missing_field" /
  #   "type_mismatch" / "extra_field" satisfy the "missing" / "type
  #   mismatch" / "extra" fuzzy synonyms naturally.
  #
  # * `subset?/2` implements the reference's contains/subset semantics
  #   for `expect`: every expected key must be present and equal (maps
  #   recurse; lists must have equal length and match pairwise).

  alias A2UICore.Error

  import ExUnit.Assertions

  # A YAML `category` expectation may accept several of our categories:
  # the Python harness maps categories to exception *tuples*, and
  # `pytest.raises` also accepts subclasses (A2uiIntegrityError and
  # A2uiRecursionError subclass A2uiValidationError).
  @category_aliases %{
    "ParseError" => [:parse, :expression],
    "ValidationError" => [:validation, :integrity, :recursion],
    "CatalogError" => [:catalog],
    "IntegrityError" => [:integrity, :recursion],
    "RecursionError" => [:recursion],
    "CompilationError" => [:compilation],
    "DataError" => [:data],
    "ExpressionError" => [:expression],
    "StateError" => [:state]
  }

  @doc """
  Asserts that `actual` (an `%A2UICore.Error{}` or `{:error, error}`
  tuple, plus its details) satisfies the YAML `expectError` expectation
  (a message string or a map of `category`/`message`/`code`/`details`).

  Each expected detail (`path`, `code`) must be found among the error's
  details. Paths compare in dotted form; an expected path also matches
  the tail of a longer one, so `children` is found at
  `components.root.children`.
  """
  @spec assert_error(term(), term()) :: true
  def assert_error(expected, actual) do
    error = unwrap(actual)
    details = error_details(error)

    {category, message, code, expected_details} = parse_expectation(expected)

    assert_category!(category, error)
    assert_message!(message, error, details)
    assert_code!(code, error, details)
    assert_details!(expected_details, details)
  end

  defp unwrap({:error, error}), do: error
  defp unwrap(%Error{} = error), do: error
  defp unwrap(other), do: other

  defp error_details(%Error{details: details}), do: Enum.map(details, &normalize_detail/1)
  defp error_details(_), do: []

  defp normalize_detail(%{code: c, message: m} = detail),
    do: %{code: to_string(c), message: m, path: Map.get(detail, :path)}

  defp normalize_detail(detail) when is_map(detail), do: detail
  defp normalize_detail(other), do: %{code: "", message: to_string(other), path: nil}

  defp parse_expectation(expected) when is_binary(expected), do: {nil, expected, nil, []}

  defp parse_expectation(expected) when is_map(expected) do
    {
      expected["category"] || expected["error"],
      expected["message"],
      expected["code"],
      if(is_list(expected["details"]), do: expected["details"], else: [])
    }
  end

  defp assert_category!(nil, _error), do: true

  # An unknown category accepts any library error, like the reference's
  # `CATEGORY_TO_EXCEPTION.get(category, (A2uiError, ValueError))`.
  defp assert_category!(category, %Error{}) when not is_map_key(@category_aliases, category),
    do: true

  defp assert_category!(category, error) when is_binary(category) do
    allowed = Map.get(@category_aliases, category, [])

    actual =
      case error do
        %Error{category: actual_category} -> actual_category
        _other -> :unknown
      end

    unless actual in allowed do
      flunk(
        "expected error category #{inspect(category)} (any of #{inspect(allowed)}), " <>
          "got #{inspect(actual)}"
      )
    end

    true
  end

  defp assert_message!(nil, _error, _details), do: true

  defp assert_message!(message, error, details) do
    err_text = error_text(error)
    detail_messages = Enum.map(details, & &1.message)
    detail_codes = Enum.map(details, & &1.code)

    err_str =
      String.downcase(
        Enum.join([err_text, Enum.join(detail_messages, " "), Enum.join(detail_codes, " ")], " ")
      )

    msg_norm = String.downcase(message)

    matched? =
      String.contains?(err_text, message) or
        Enum.any?(detail_messages, &String.contains?(&1, message)) or
        regex_search?(escape_regex(message), err_text) or
        regex_search?(message, err_text) or
        fuzzy_match?(msg_norm, err_str)

    unless matched? do
      flunk("expected error message #{inspect(message)} not found in #{inspect(err_str)}")
    end

    true
  end

  defp assert_code!(nil, _error, _details), do: true

  defp assert_code!(code, error, details) do
    detail_codes = Enum.map(details, & &1.code)
    error_code = error_code(error)

    matched? =
      code in detail_codes or
        code == error_code or
        String.contains?(error_text(error), code)

    unless matched? do
      flunk(
        "expected error code #{inspect(code)} not found in details #{inspect(detail_codes)} " <>
          "or error code #{inspect(error_code)}"
      )
    end

    true
  end

  defp assert_details!([], _details), do: true

  defp assert_details!(expected, details) do
    for %{} = wanted <- expected, not Enum.any?(details, &detail_matches?(&1, wanted)) do
      flunk(
        "expected detail #{inspect(wanted)} not found in " <>
          inspect(Enum.map(details, &Map.take(&1, [:path, :code])))
      )
    end

    true
  end

  defp detail_matches?(actual, wanted) do
    code_matches?(actual.code, wanted["code"]) and path_matches?(actual.path, wanted["path"])
  end

  defp code_matches?(_actual, nil), do: true
  defp code_matches?(actual, wanted), do: actual == to_string(wanted)

  defp path_matches?(_actual, nil), do: true
  defp path_matches?(nil, _wanted), do: false

  defp path_matches?(actual, wanted) do
    actual = dotted(actual)
    wanted = dotted(wanted)

    actual == wanted or String.ends_with?(actual, "." <> wanted)
  end

  # `/children/0` and `children.0` name the same location.
  defp dotted("/" <> pointer), do: String.replace(pointer, "/", ".")
  defp dotted(path), do: path

  defp error_code(%Error{code: code}), do: code
  defp error_code(_), do: nil

  defp error_text(%Error{message: message}), do: to_string(message)
  defp error_text(other), do: inspect(other)

  defp regex_search?(pattern, subject) do
    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.match?(regex, subject)
      {:error, _} -> false
    end
  rescue
    _ -> false
  end

  defp escape_regex(message), do: Regex.escape(message)

  # The reference's lowercase fuzzy synonym table: `{expected substring,
  # synonyms that satisfy it in the actual error string}`. Each entry
  # corresponds to one `or` branch of the reference's `assert_raises`.
  @fuzzy_synonyms [
    {"not of type", ["input should be", "type_mismatch", "must be a"]},
    {"is a required property", ["field required", "missing"]},
    {"additional properties are not allowed", ["extra inputs are not permitted", "extra"]},
    {"circular", ["circular", "self-reference"]},
    {"orphan", ["orphan"]},
    {"was unexpected", ["unrecognized", "unexpected"]},
    {"cannot contain child", ["cannot contain child"]},
    {"cannot be placed under parent", ["cannot be placed under parent"]},
    {"protocol version mismatch", ["mismatched protocol", "protocol version mismatch"]},
    {"mismatched protocol", ["mismatched protocol", "protocol version mismatch"]}
  ]

  defp fuzzy_match?(msg_norm, err_str) do
    Enum.any?(@fuzzy_synonyms, fn {expected, synonyms} ->
      String.contains?(msg_norm, expected) and
        Enum.any?(synonyms, &String.contains?(err_str, &1))
    end)
  end

  # ------------------------------------------------------------ expect ----

  @doc """
  Subset/contains matching for `expect` blocks: every expected key must
  be present; maps recurse; lists must be equal length and pair off;
  scalars compare with JSON equality (so `1` matches `1.0`).
  """
  @spec subset?(term(), term()) :: boolean()
  def subset?(expected, actual) when is_map(expected) and is_map(actual) do
    Enum.all?(expected, fn {key, value} ->
      Map.has_key?(actual, key) and subset?(value, Map.get(actual, key))
    end)
  end

  def subset?(expected, actual) when is_list(expected) and is_list(actual) do
    length(expected) == length(actual) and
      Enum.all?(Enum.zip(expected, actual), fn {e, a} -> subset?(e, a) end)
  end

  def subset?(expected, actual), do: json_equal?(expected, actual)

  defp json_equal?(a, b) when is_number(a) and is_number(b), do: a == b
  defp json_equal?(a, b) when is_map(a) and is_map(b), do: subset?(a, b) and subset?(b, a)
  defp json_equal?(a, b) when is_list(a) and is_list(b), do: json_list_equal?(a, b)
  defp json_equal?(a, b), do: a === b

  defp json_list_equal?(a, b) do
    length(a) == length(b) and Enum.all?(Enum.zip(a, b), fn {x, y} -> json_equal?(x, y) end)
  end

  @doc """
  Exact JSON equality (numbers compare by value, so `1` equals `1.0`),
  raising a helpful message on failure. Use for data models, themes,
  capabilities and data-model reads, which the reference compares with
  `==`.
  """
  @spec assert_json_equal(term(), term(), String.t()) :: true
  def assert_json_equal(expected, actual, what) do
    unless json_equal?(expected, actual) do
      flunk(
        "#{what}:\nexpected #{inspect(expected, pretty: true)}\ngot " <>
          inspect(actual, pretty: true, limit: :infinity)
      )
    end

    true
  end

  @doc """
  Strict structural equality for schema documents (the reference
  compares canonical JSON strings): like `assert_json_equal/3` but `1`
  and `1.0` differ.
  """
  @spec assert_strict_equal(term(), term(), String.t()) :: true
  def assert_strict_equal(expected, actual, what) do
    unless expected === actual do
      flunk("#{what}: documents differ\n" <> diff_summary(expected, actual, []))
    end

    true
  end

  defp diff_summary(a, b, path) when is_map(a) and is_map(b) do
    keys = Enum.sort(Enum.uniq(Map.keys(a) ++ Map.keys(b)))

    Enum.find_value(keys, "", fn key ->
      case {Map.fetch(a, key), Map.fetch(b, key)} do
        {{:ok, x}, {:ok, y}} when x === y -> nil
        {{:ok, x}, {:ok, y}} -> diff_summary(x, y, path ++ [key])
        {{:ok, _}, :error} -> "missing #{format_path(path ++ [key])} in actual"
        {:error, {:ok, _}} -> "unexpected #{format_path(path ++ [key])} in actual"
      end
    end)
  end

  defp diff_summary(a, b, path) when is_list(a) and is_list(b) and length(a) == length(b) do
    a
    |> Enum.zip(b)
    |> Enum.with_index()
    |> Enum.find_value("", fn
      {{x, y}, _i} when x === y -> nil
      {{x, y}, i} -> diff_summary(x, y, path ++ [i])
    end)
  end

  defp diff_summary(a, b, path),
    do: "at #{format_path(path)}: expected #{inspect(a)}, got #{inspect(b)}"

  defp format_path([]), do: "/"
  defp format_path(path), do: "/" <> Enum.map_join(path, "/", &to_string/1)

  @doc """
  Asserts the subset expectation, raising a helpful message on failure.
  """
  @spec assert_subset(term(), term(), String.t()) :: true
  def assert_subset(expected, actual, what) do
    unless subset?(expected, actual) do
      flunk(
        "#{what}:\nexpected #{inspect(expected, pretty: true)} to be a subset of\n" <>
          inspect(actual, pretty: true, limit: :infinity)
      )
    end

    true
  end
end
