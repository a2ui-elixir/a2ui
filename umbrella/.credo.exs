%{
  configs: [
    %{
      name: "default",
      strict: true,
      checks: %{
        disabled: [
          # Both `_` and `_descriptive` are accepted for unused variables:
          # `_` in throwaway pattern fragments (`{_ , []}`), `_descriptive`
          # in multi-clause heads where the name documents the wire field.
          {Credo.Check.Consistency.UnusedVariableNames,
           "accept both anonymous and descriptive unused-variable names"}
        ],
        extra: [
          # Consistent orderings and groups keep diffs small.
          {Credo.Check.Consistency.ParameterPatternMatching, []},
          {Credo.Check.Consistency.SpaceAroundOperators, []}
        ]
      }
    }
  ]
}
