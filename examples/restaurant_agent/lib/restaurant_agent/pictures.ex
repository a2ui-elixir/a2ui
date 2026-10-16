defmodule RestaurantAgent.Pictures do
  @moduledoc """
  The restaurants' pictures: each restaurant's dish on its table, seen
  from above, drawn in SVG (480 by 320). The agent serves them itself
  (`GET /images/<id>.svg`), so the examples need no network.
  """

  @doc "The picture of the restaurant `id`, or `nil` for an id it does not know."
  @spec svg(String.t()) :: String.t() | nil
  def svg(id) do
    case scene(id) do
      nil -> nil
      {table, body} -> render(table, body)
    end
  end

  defp scene("trattoria-roma"),
    do: {gingham("#b8392a"), [cutlery(), plate(250, 160, 118), pasta()]}

  defp scene("osteria-del-ponte"),
    do: {planks("#2f6067", "#1a3a3f"), [cutlery(), plate(250, 160, 118), fish()]}

  defp scene("pizzeria-napoli"), do: {flour("#41454c", "#1f2226"), [board(), pizza()]}
  defp scene("sakura"), do: {petals("#f6d6dd", "#e3a0b2"), [slate(), sushi()]}
  defp scene("ramen-ya"), do: {planks("#3a3f45", "#191c1f"), [ramen()]}

  defp scene("la-cantina"),
    do: {dots("#1fa199", "#0f6c67", "#ffffff"), [plate(250, 162, 122), tacos()]}

  defp scene("spice-route"),
    do: {dots("#3a4086", "#1e2259", "#f2c14e"), [plate(250, 162, 122), curry()]}

  defp scene("le-petit-bistro"),
    do: {linen("#2f548c", "#1a325a"), [cutlery(), plate(250, 160, 118), steak()]}

  defp scene(_id), do: nil

  defp render(table, body) do
    IO.iodata_to_binary([
      ~s|<svg xmlns="http://www.w3.org/2000/svg" width="480" height="320" viewBox="0 0 480 320">|,
      defs(),
      table,
      ~s|<rect width="480" height="320" fill="url(#light)"/>|,
      body,
      "</svg>\n"
    ])
  end

  defp defs do
    ~S"""
    <defs>
      <radialGradient id="light" cx="0.18" cy="0.08" r="1">
        <stop offset="0" stop-color="#fff" stop-opacity="0.24"/>
        <stop offset="0.6" stop-color="#fff" stop-opacity="0"/>
      </radialGradient>
      <radialGradient id="plate" cx="0.42" cy="0.36" r="0.75">
        <stop offset="0" stop-color="#ffffff"/>
        <stop offset="1" stop-color="#e6e1d9"/>
      </radialGradient>
      <filter id="shadow" x="-40%" y="-40%" width="180%" height="180%">
        <feGaussianBlur in="SourceAlpha" stdDeviation="7"/>
        <feOffset dx="3" dy="9"/>
        <feComponentTransfer><feFuncA type="linear" slope="0.38"/></feComponentTransfer>
        <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
      </filter>
      <filter id="soft" x="-20%" y="-20%" width="140%" height="140%">
        <feGaussianBlur in="SourceAlpha" stdDeviation="2.5"/>
        <feOffset dx="1" dy="3"/>
        <feComponentTransfer><feFuncA type="linear" slope="0.3"/></feComponentTransfer>
        <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
      </filter>
    </defs>
    """
  end

  # -- tables -------------------------------------------------------------------------

  defp gradient(light, dark) do
    ~s"""
    <defs><linearGradient id="table" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#{light}"/><stop offset="1" stop-color="#{dark}"/>
    </linearGradient></defs>
    <rect width="480" height="320" fill="url(#table)"/>
    """
  end

  defp gingham(red) do
    ~s"""
    <defs><pattern id="cloth" width="44" height="44" patternUnits="userSpaceOnUse" patternTransform="rotate(-8)">
      <rect width="44" height="44" fill="#f8f1e6"/>
      <rect width="22" height="44" fill="#{red}" fill-opacity="0.3"/>
      <rect width="44" height="22" fill="#{red}" fill-opacity="0.3"/>
    </pattern></defs>
    <rect width="480" height="320" fill="url(#cloth)"/>
    """
  end

  defp planks(light, dark) do
    [
      gradient(light, dark),
      ~S"""
      <path d="M0 64H480M0 144H480M0 224H480M0 304H480" stroke="#000" stroke-opacity="0.24" stroke-width="2"/>
      <path d="M0 30C120 22 260 38 480 28M0 104C150 112 300 96 480 106M0 186C140 178 330 194 480 182M0 266C170 274 320 258 480 270" fill="none" stroke="#fff" stroke-opacity="0.05" stroke-width="2"/>
      """
    ]
  end

  defp flour(light, dark) do
    specks =
      for {x, y, r} <- [
            {38, 46, 2.2},
            {64, 92, 1.4},
            {30, 230, 1.8},
            {88, 284, 2.4},
            {420, 40, 1.6},
            {446, 96, 2.2},
            {452, 250, 1.6},
            {404, 292, 2},
            {120, 26, 1.2},
            {360, 18, 1.8},
            {20, 150, 1.4},
            {466, 176, 1.2}
          ],
          do: ~s|<circle cx="#{x}" cy="#{y}" r="#{r}"/>|

    [gradient(light, dark), ~s|<g fill="#fff" fill-opacity="0.4">|, specks, "</g>"]
  end

  defp petals(light, dark) do
    petals =
      for {x, y, angle} <- [
            {54, 50, 20},
            {420, 36, -30},
            {448, 270, 60},
            {36, 262, -50},
            {120, 296, 10},
            {396, 300, 80}
          ],
          do:
            ~s|<path transform="translate(#{x} #{y}) rotate(#{angle})" d="M0-10C7-7 7 5 0 10C-7 5-7-7 0-10Z"/>|

    [gradient(light, dark), ~s|<g fill="#fff" fill-opacity="0.6">|, petals, "</g>"]
  end

  defp dots(light, dark, dot) do
    [
      gradient(light, dark),
      ~s"""
      <defs><pattern id="dots" width="24" height="24" patternUnits="userSpaceOnUse">
        <circle cx="12" cy="12" r="1.6" fill="#{dot}" fill-opacity="0.16"/>
      </pattern></defs>
      <rect width="480" height="320" fill="url(#dots)"/>
      """
    ]
  end

  defp linen(light, dark) do
    [
      gradient(light, dark),
      ~S"""
      <defs><pattern id="linen" width="8" height="8" patternUnits="userSpaceOnUse">
        <path d="M0 0L8 8M8 0L0 8" stroke="#fff" stroke-opacity="0.05" stroke-width="1"/>
      </pattern></defs>
      <rect width="480" height="320" fill="url(#linen)"/>
      <rect x="54" y="40" width="72" height="240" rx="6" fill="#f6f4ef" filter="url(#soft)"/>
      <path d="M66 40V280M78 40V280M102 40V280M114 40V280" stroke="#2f548c" stroke-opacity="0.35" stroke-width="3"/>
      """
    ]
  end

  # -- tableware ----------------------------------------------------------------------

  defp plate(cx, cy, r) do
    ~s"""
    <circle cx="#{cx}" cy="#{cy}" r="#{r}" fill="url(#plate)" filter="url(#shadow)"/>
    <circle cx="#{cx}" cy="#{cy}" r="#{r - 24}" fill="none" stroke="#000" stroke-opacity="0.06" stroke-width="2"/>
    <circle cx="#{cx}" cy="#{cy}" r="#{r - 2}" fill="none" stroke="#fff" stroke-opacity="0.9" stroke-width="2"/>
    """
  end

  defp cutlery do
    ~S"""
    <g fill="#f3f1ed" filter="url(#soft)">
      <path d="M74 62h4v40h4v-40h4v40h4v-40h4v40h4v-40h4v50c0 8-4 14-9 16v122a5 5 0 0 1-10 0V128c-5-2-9-8-9-16z"/>
      <path d="M404 58c16 12 22 60 14 102h-14z"/>
      <path d="M402 158h18v96a9 9 0 0 1-18 0z"/>
    </g>
    """
  end

  defp leaf(x, y, angle, scale \\ 1, fill \\ "#2f8f3f") do
    ~s|<g transform="translate(#{x} #{y}) rotate(#{angle}) scale(#{scale})">| <>
      ~s|<path d="M0-16C10-9 10 9 0 16C-10 9-10-9 0-16Z" fill="#{fill}"/>| <>
      ~s|<path d="M0-13V13" stroke="#fff" stroke-opacity="0.35" stroke-width="1.4"/></g>|
  end

  # -- dishes -------------------------------------------------------------------------

  defp pasta do
    nest = [
      {72, 48, -10},
      {64, 44, 22},
      {58, 40, -36},
      {52, 36, 52},
      {46, 30, -62},
      {38, 26, 14},
      {30, 20, -28},
      {66, 32, 74},
      {56, 46, 38}
    ]

    noodles = fn stroke, width, extra ->
      [
        ~s|<g fill="none" stroke="#{stroke}" stroke-width="#{width}" #{extra}>|,
        for {{rx, ry, angle}, index} <- Enum.with_index(nest) do
          cx = 248 + rem(index * 7, 5)
          cy = 164 + rem(index * 5, 4)

          ~s|<ellipse cx="#{cx}" cy="#{cy}" rx="#{rx}" ry="#{ry}" transform="rotate(#{angle} #{cx} #{cy})"/>|
        end,
        "</g>"
      ]
    end

    cheese =
      for {x, y, angle} <- [
            {206, 150, 20},
            {222, 196, -15},
            {288, 186, 40},
            {300, 150, 10},
            {240, 214, 30},
            {270, 206, -25},
            {214, 172, 55},
            {292, 128, -10}
          ],
          do:
            ~s|<rect x="#{x}" y="#{y}" width="4.5" height="4.5" rx="1" fill="#fff8e1" transform="rotate(#{angle} #{x} #{y})"/>|

    [
      ~s|<g filter="url(#soft)">|,
      noodles.("#d19633", 7.5, ""),
      noodles.("#f2cb66", 4.5, ""),
      "</g>",
      noodles.("#fff1bf", 1.6, ~s(stroke-dasharray="16 30" stroke-linecap="round")),
      ~S"""
      <g filter="url(#soft)">
        <path d="M224 148c0-17 24-28 42-20 15 6 20 24 10 36-9 11-29 14-42 7-7-4-10-12-10-23z" fill="#b52d20"/>
      </g>
      <path d="M232 146c2-11 18-17 30-12 10 4 12 16 5 24-7 8-21 9-29 3-5-4-7-9-6-15z" fill="#d6432e"/>
      <ellipse cx="246" cy="139" rx="7" ry="4" fill="#fff" fill-opacity="0.35" transform="rotate(-20 246 139)"/>
      """,
      leaf(270, 134, 38),
      leaf(256, 126, -24, 0.85, "#3a9a48"),
      cheese
    ]
  end

  defp board do
    ~S"""
    <rect x="22" y="150" width="110" height="26" rx="13" fill="#b07a45" filter="url(#soft)"/>
    <circle cx="250" cy="164" r="136" fill="#c68d55" filter="url(#shadow)"/>
    <circle cx="250" cy="164" r="129" fill="none" stroke="#a36c3a" stroke-width="3"/>
    <path d="M140 108c40-10 96-8 130 0M124 196c64 14 150 12 222-6M164 252c52 8 112 6 164-8" fill="none" stroke="#8a5a2f" stroke-opacity="0.3" stroke-width="2"/>
    """
  end

  defp pizza do
    char =
      for angle <- [12, 58, 101, 147, 196, 238, 284, 331] do
        rad = angle * :math.pi() / 180
        x = Float.round(250 + 103 * :math.cos(rad), 1)
        y = Float.round(164 + 103 * :math.sin(rad), 1)

        ~s|<ellipse cx="#{x}" cy="#{y}" rx="6" ry="3.5" transform="rotate(#{angle + 90} #{x} #{y})"/>|
      end

    cheese =
      for {dx, dy, r} <- [
            {-42, -36, 21},
            {30, -50, 17},
            {56, 8, 22},
            {-4, 42, 20},
            {-56, 22, 15},
            {14, -4, 13},
            {-22, -64, 12},
            {44, 56, 13}
          ],
          do:
            ~s|<circle cx="#{250 + dx}" cy="#{164 + dy}" r="#{r}" fill="#fdf5df" stroke="#efd8a6" stroke-width="2"/>|

    [
      ~S"""
      <defs>
        <radialGradient id="crust" cx="0.5" cy="0.5" r="0.5">
          <stop offset="0.8" stop-color="#ebb66c"/><stop offset="1" stop-color="#c98a3e"/>
        </radialGradient>
        <radialGradient id="sauce" cx="0.45" cy="0.4" r="0.6">
          <stop offset="0" stop-color="#da4b2c"/><stop offset="1" stop-color="#b52f1a"/>
        </radialGradient>
      </defs>
      <circle cx="250" cy="164" r="112" fill="url(#crust)" filter="url(#soft)"/>
      """,
      ~s|<g fill="#5d3218" fill-opacity="0.45">|,
      char,
      "</g>",
      ~s|<circle cx="250" cy="164" r="95" fill="url(#sauce)"/>|,
      cheese,
      leaf(222, 140, -30),
      leaf(290, 150, 50, 0.9),
      leaf(258, 204, 10, 0.9),
      leaf(214, 190, 70, 0.8, "#3a9a48"),
      ~S"""
      <path d="M250 52V276M153 108L347 220M153 220L347 108" stroke="#9e2a16" stroke-opacity="0.32" stroke-width="2"/>
      <g fill="#fff" fill-opacity="0.32">
        <ellipse cx="236" cy="122" rx="5" ry="2.5" transform="rotate(-20 236 122)"/>
        <ellipse cx="296" cy="196" rx="4" ry="2" transform="rotate(30 296 196)"/>
      </g>
      """
    ]
  end

  defp fish do
    herbs =
      for {x, y, angle} <- [{196, 206, -30}, {214, 216, 20}, {182, 120, 60}],
          do: leaf(x, y, angle, 0.55, "#4a9c3a")

    [
      ~S"""
      <defs><linearGradient id="skin" x1="0" y1="0" x2="0" y2="1">
        <stop offset="0" stop-color="#e6c891"/><stop offset="1" stop-color="#b48650"/>
      </linearGradient></defs>
      <path d="M170 160c22-34 94-42 144-16l32-18c-4 22-4 46 0 68l-32-18c-50 26-122 18-144-16z" fill="url(#skin)" filter="url(#soft)"/>
      <path d="M204 136l20 50M228 130l20 54M252 128l20 56M276 132l18 50" stroke="#6b4423" stroke-opacity="0.5" stroke-width="4" stroke-linecap="round"/>
      <path d="M198 140c6 10 6 30 0 42" fill="none" stroke="#8a6a3b" stroke-opacity="0.6" stroke-width="2"/>
      <circle cx="184" cy="154" r="4.5" fill="#2b2b2b"/>
      <circle cx="185.5" cy="152.5" r="1.4" fill="#fff"/>
      <g transform="translate(286 214)">
        <path d="M-24 0A24 24 0 0 1 24 0Z" fill="#f9d54a" stroke="#f0b51e" stroke-width="3"/>
        <path d="M0 0L-15-14M0 0L0-20M0 0L15-14" stroke="#fff3b0" stroke-width="2"/>
      </g>
      <circle cx="318" cy="200" r="9" fill="#d63a2f"/>
      <circle cx="320" cy="222" r="8" fill="#c8322a"/>
      <circle cx="315" cy="197" r="2.5" fill="#fff" fill-opacity="0.5"/>
      """,
      herbs
    ]
  end

  defp slate do
    ~S"""
    <g transform="rotate(-6 245 166)" filter="url(#shadow)">
      <rect x="108" y="92" width="276" height="148" rx="18" fill="#2a2c31"/>
      <rect x="116" y="100" width="260" height="132" rx="13" fill="none" stroke="#3b3e45" stroke-width="2"/>
    </g>
    <g stroke="#2b2118" stroke-width="7" stroke-linecap="round">
      <path d="M290 280L452 214"/><path d="M300 292L462 226"/>
    </g>
    <g stroke="#c0392b" stroke-width="7" stroke-linecap="round">
      <path d="M430 223L452 214"/><path d="M440 235L462 226"/>
    </g>
    """
  end

  defp sushi do
    maki =
      for {x, y} <- [{170, 142}, {222, 136}, {274, 130}] do
        rice =
          for {dx, dy} <- [{-9, -8}, {8, -10}, {11, 6}, {-10, 7}, {0, 12}],
              do: ~s|<circle cx="#{x + dx}" cy="#{y + dy}" r="1.6"/>|

        [
          ~s|<circle cx="#{x}" cy="#{y}" r="24" fill="#1c3325" stroke="#2f4a38" stroke-width="2"/>|,
          ~s|<circle cx="#{x}" cy="#{y}" r="19" fill="#faf8f1"/>|,
          ~s|<g fill="#e3ddcd">|,
          rice,
          "</g>",
          ~s|<circle cx="#{x - 2}" cy="#{y - 1}" r="8" fill="#f2895a"/>|,
          ~s|<rect x="#{x + 3}" y="#{y + 2}" width="7" height="6" rx="2" fill="#8cc152"/>|
        ]
      end

    nigiri =
      for {x, y} <- [{196, 196}, {268, 188}] do
        [
          ~s|<rect x="#{x - 28}" y="#{y - 12}" width="56" height="26" rx="13" fill="#faf8f1" transform="rotate(-6 #{x} #{y})"/>|,
          ~s|<rect x="#{x - 31}" y="#{y - 15}" width="62" height="22" rx="11" fill="#f39063" transform="rotate(-6 #{x} #{y})"/>|,
          ~s|<path d="M#{x - 16} #{y - 12}l-6 16M#{x - 2} #{y - 14}l-6 18M#{x + 12} #{y - 15}l-6 18" stroke="#fde2d2" stroke-width="3" stroke-linecap="round"/>|
        ]
      end

    [
      ~s|<g transform="rotate(-6 245 166)">|,
      maki,
      nigiri,
      ~S"""
      <path d="M326 134c8-9 22-6 24 4 2 11-12 16-20 12-7-3-9-10-4-16z" fill="#9ccc65"/>
      <g fill="#f7b9c6" stroke="#f093a8" stroke-width="1.5">
        <path d="M322 184c10-10 26-6 26 6-10 6-20 4-26-6z"/>
        <path d="M330 196c12-6 24 2 22 12-12 2-20-2-22-12z"/>
      </g>
      </g>
      """
    ]
  end

  defp ramen do
    noodles =
      for y <- [176, 186, 196, 206, 216, 226] do
        ~s|<path d="M150 #{y}q10-8 20 0t20 0t20 0t20 0t20 0" />|
      end

    scallions =
      for {x, y} <- [
            {226, 166},
            {238, 176},
            {216, 186},
            {262, 150},
            {250, 168},
            {274, 186},
            {206, 160},
            {286, 158}
          ],
          do: ~s|<circle cx="#{x}" cy="#{y}" r="4.2"/>|

    [
      ~S"""
      <defs>
        <radialGradient id="broth" cx="0.45" cy="0.42" r="0.6">
          <stop offset="0" stop-color="#f3c88f"/><stop offset="1" stop-color="#d8924c"/>
        </radialGradient>
        <radialGradient id="yolk" cx="0.4" cy="0.4" r="0.6">
          <stop offset="0" stop-color="#ffc061"/><stop offset="1" stop-color="#ef7b12"/>
        </radialGradient>
        <clipPath id="bowl"><circle cx="246" cy="164" r="104"/></clipPath>
      </defs>
      <circle cx="246" cy="164" r="126" fill="#1d1d20" filter="url(#shadow)"/>
      <circle cx="246" cy="164" r="124" fill="none" stroke="#3b3b41" stroke-width="3"/>
      <circle cx="246" cy="164" r="115" fill="none" stroke="#c0392b" stroke-width="5" stroke-dasharray="3 9"/>
      <circle cx="246" cy="164" r="104" fill="url(#broth)"/>
      <g clip-path="url(#bowl)">
      """,
      ~s|<g fill="none" stroke="#f7e1a3" stroke-width="5" stroke-linecap="round">|,
      noodles,
      "</g>",
      ~S"""
      <rect x="302" y="58" width="46" height="74" rx="3" fill="#1d2a22" transform="rotate(18 325 95)"/>
      <circle cx="292" cy="130" r="28" fill="#ecbba5" stroke="#a6563a" stroke-width="6"/>
      <path d="M280 124c6-8 20-6 22 4s-10 14-16 8" fill="none" stroke="#f8dccd" stroke-width="3"/>
      <circle cx="318" cy="176" r="24" fill="#ecbba5" stroke="#a6563a" stroke-width="6"/>
      <path d="M308 172c5-7 17-5 19 3s-8 12-14 7" fill="none" stroke="#f8dccd" stroke-width="3"/>
      <g transform="rotate(-20 206 124)">
        <ellipse cx="206" cy="124" rx="26" ry="20" fill="#fffdf6"/>
        <circle cx="208" cy="124" r="12" fill="url(#yolk)"/>
      </g>
      <g transform="rotate(25 242 104)">
        <ellipse cx="242" cy="104" rx="24" ry="18" fill="#fffdf6"/>
        <circle cx="244" cy="104" r="11" fill="url(#yolk)"/>
      </g>
      <circle cx="262" cy="214" r="14" fill="#fffdf9"/>
      <path d="M262 214m-6 0a6 6 0 1 1 6 6a4 4 0 1 1-4-4" fill="none" stroke="#ef6f8f" stroke-width="2.5"/>
      """,
      ~s|<g fill="none" stroke="#6fbf45" stroke-width="2.5">|,
      scallions,
      "</g></g>",
      ~S"""
      <g stroke-linecap="round" stroke-width="8">
        <path d="M330 30L470 112" stroke="#2b2118"/>
        <path d="M344 22L478 100" stroke="#2b2118"/>
      </g>
      """
    ]
  end

  defp tacos do
    taco = fn x, y, angle ->
      ~s"""
      <g transform="rotate(#{angle} #{x} #{y})" filter="url(#soft)">
        <ellipse cx="#{x}" cy="#{y}" rx="54" ry="31" fill="#f2cf8c" stroke="#d9a85a" stroke-width="3"/>
        <ellipse cx="#{x}" cy="#{y}" rx="41" ry="19" fill="#9c4a2b"/>
        <rect x="#{x - 30}" y="#{y - 9}" width="16" height="6" rx="3" fill="#7d3a20"/>
        <rect x="#{x + 6}" y="#{y + 2}" width="18" height="6" rx="3" fill="#7d3a20"/>
        <rect x="#{x - 12}" y="#{y - 6}" width="7" height="7" rx="1.5" fill="#f6c945"/>
        <rect x="#{x + 14}" y="#{y - 10}" width="7" height="7" rx="1.5" fill="#f6c945"/>
        <rect x="#{x - 24}" y="#{y + 3}" width="5" height="5" rx="1" fill="#fff"/>
        <rect x="#{x + 2}" y="#{y - 12}" width="5" height="5" rx="1" fill="#fff"/>
        <circle cx="#{x - 4}" cy="#{y + 8}" r="3" fill="#d6332a"/>
        <circle cx="#{x + 26}" cy="#{y + 6}" r="3" fill="#d6332a"/>
        <path d="M#{x - 16} #{y - 2}l4-6l4 6zM#{x + 22} #{y + 9}l4-6l4 6zM#{x - 2} #{y + 2}l4-6l4 6z" fill="#3f9b3a"/>
      </g>
      """
    end

    lime = fn x, y, angle ->
      ~s"""
      <g transform="translate(#{x} #{y}) rotate(#{angle})">
        <path d="M-20 0A20 20 0 0 1 20 0Z" fill="#7cb342"/>
        <path d="M-16 0A16 16 0 0 1 16 0Z" fill="#d4e157"/>
        <path d="M0 0L-11-11M0 0L0-15M0 0L11-11" stroke="#7cb342" stroke-width="1.5"/>
      </g>
      """
    end

    [
      taco.(214, 128, -18),
      taco.(262, 170, 8),
      taco.(214, 210, -8),
      lime.(318, 120, 20),
      lime.(320, 208, 160)
    ]
  end

  defp curry do
    spots =
      for {x, y} <- [{318, 150}, {346, 132}, {372, 160}, {338, 192}, {362, 198}],
          do: ~s|<ellipse cx="#{x}" cy="#{y}" rx="6" ry="4"/>|

    [
      ~S"""
      <defs><radialGradient id="curry" cx="0.45" cy="0.4" r="0.6">
        <stop offset="0" stop-color="#f39443"/><stop offset="1" stop-color="#c8531b"/>
      </radialGradient></defs>
      <path d="M302 150c28-40 98-30 102 18 4 46-64 68-92 42-16-14-20-42-10-60z" fill="#e8c07a" filter="url(#soft)"/>
      """,
      ~s|<g fill="#9a6a35" fill-opacity="0.55">|,
      spots,
      "</g>",
      ~S"""
      <circle cx="226" cy="162" r="74" fill="#b87333" filter="url(#soft)"/>
      <circle cx="226" cy="162" r="64" fill="url(#curry)"/>
      <path d="M226 162m-6 0a6 6 0 1 1 12 0a12 12 0 1 1-24 0a18 18 0 1 1 36 0a24 24 0 1 1-48 0" fill="none" stroke="#fff3e0" stroke-opacity="0.9" stroke-width="4" stroke-linecap="round"/>
      <path d="M268 112c6-4 14-2 16 4" fill="none" stroke="#d6332a" stroke-width="4" stroke-linecap="round"/>
      """,
      leaf(200, 132, -40, 0.6, "#3f9b3a"),
      leaf(250, 198, 30, 0.6, "#3f9b3a"),
      leaf(196, 192, 80, 0.5, "#4caf50")
    ]
  end

  defp steak do
    fries =
      for {x, y, angle} <- [
            {300, 140, -18},
            {314, 146, 8},
            {326, 140, -30},
            {290, 160, 20},
            {306, 168, -6},
            {322, 170, 28},
            {296, 186, -24},
            {316, 192, 12},
            {334, 186, -12}
          ],
          do:
            ~s|<rect x="#{x - 5}" y="#{y - 28}" width="10" height="56" rx="5" fill="#f4c55a" stroke="#d6992c" stroke-width="1.5" transform="rotate(#{angle} #{x} #{y})"/>|

    greens =
      for {x, y, angle} <- [{204, 224, -60}, {224, 232, -20}, {246, 228, 30}],
          do: leaf(x, y, angle, 0.6, "#4f9a3a")

    [
      ~S"""
      <defs><radialGradient id="beef" cx="0.4" cy="0.35" r="0.7">
        <stop offset="0" stop-color="#8e4b2f"/><stop offset="1" stop-color="#5a2c1a"/>
      </radialGradient></defs>
      <path d="M186 130c26-22 88-16 100 14 12 32-20 60-62 58-36-2-60-36-38-72z" fill="url(#beef)" filter="url(#soft)"/>
      <path d="M200 132l40 56M222 124l40 58M246 124l32 50" stroke="#3a1c0f" stroke-opacity="0.55" stroke-width="5" stroke-linecap="round"/>
      <rect x="220" y="146" width="28" height="22" rx="6" fill="#f7e7a6"/>
      <g fill="#5c9b3a"><circle cx="228" cy="153" r="1.6"/><circle cx="240" cy="158" r="1.6"/><circle cx="232" cy="162" r="1.6"/></g>
      """,
      ~s|<g filter="url(#soft)">|,
      fries,
      "</g>",
      greens
    ]
  end
end
