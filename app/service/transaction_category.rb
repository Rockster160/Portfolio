# The category vocabulary for spending.
#
# CAUTION — this is the fourth copy of this list, not the first. It also lives
# in:
#
#   * Jil task 453 "Transaction Category Rules", as the Keyval keys of the
#     merchant-pattern rules. That task is what actually auto-assigns a
#     category from a merchant string.
#   * The `choices` on the categorization Prompt each Chase alert raises.
#   * CustomChart 4 "Transactions", as the keys of its color map — a category
#     missing from there renders as an uncolored series.
#
# Rails had no source for it at all, and constraining the UI needs one, so
# this is it for the app side. Adding a category means touching all four.
# Worth unifying — task 453 is the natural owner, since it already holds the
# rules — but that is a change to a live Jil task and belongs in its own pass.
module TransactionCategory
  # Ordered as the Prompt presents them, which is roughly fixed-costs first
  # then discretionary. Kept in that order so the select matches the muscle
  # memory of answering the Prompt.
  ALL = [
    :mortgage,
    :"pay check",
    :"card payment",
    :insurance,
    :taxes,
    :hosting,
    :subscriptions,
    :groceries,
    :alcohol,
    :"eat out",
    :utilities,
    :home,
    :car,
    :pets,
    :health,
    :medical,
    :hobby,
    :travel,
    :fun,
    :people,
    :shopping,
    :other,
  ].freeze

  DEFAULT = :other

  # Mirrored from CustomChart 4's color map so a category is the same color
  # everywhere it appears. Not a validated categorical palette and cannot be —
  # 22 hues are not mutually separable, and the validator fails it on lightness
  # band, chroma floor, and CVD separation (worst adjacent pair ΔE 1.9 protan).
  #
  # That is acceptable ONLY because nothing here identifies a category by
  # color alone: every bar carries its own name and value. Color is
  # redundant reinforcement. Do not reuse this map anywhere identity depends
  # on the hue, and do not re-step it without also updating CustomChart 4 —
  # they would drift and the same category would be two colors.
  COLORS = {
    mortgage:       "#E66767",
    "pay check":    "#008300",
    "card payment": "#6E7681",
    insurance:      "#DCA3B1",
    taxes:          "#C91DC9",
    hosting:        "#A8E6CF",
    subscriptions:  "#9085E9",
    groceries:      "#3987E5",
    alcohol:        "#CBB994",
    "eat out":      "#D95926",
    utilities:      "#199E70",
    home:           "#C98500",
    car:            "#8A6D3B",
    pets:           "#B07CC6",
    health:         "#59C26A",
    medical:        "#1DC91D",
    hobby:          "#45B6D4",
    travel:         "#9EC91D",
    fun:            "#F5D67B",
    people:         "#14C8B4",
    shopping:       "#D55181",
    other:          "#AEB6C2",
  }.freeze

  FALLBACK_COLOR = "#475569".freeze

  class << self
    # Stored lowercase ("eat out"); rendered titleized ("Eat Out"). The select
    # submits the stored form so nothing round-trips into a new spelling.
    def options
      ALL.map { |category| [category.to_s.titleize, category.to_s] }
    end

    def label(category)
      category.to_s.titleize
    end

    # Strays render in a neutral grey rather than borrowing another category's
    # color, so "this is not a real category" is visible on the chart.
    def color(category)
      COLORS[category.to_s.to_sym] || FALLBACK_COLOR
    end

    def valid?(category)
      ALL.any? { |known| known.to_s == category.to_s }
    end

    # Nil rather than DEFAULT on an unknown value: silently rewriting an
    # unrecognised category to "other" would erase the fact that something
    # wrote a category nothing knows about. `Extra Expense` is in the data
    # exactly once for that reason.
    def cast(category)
      ALL.detect { |known| known.to_s == category.to_s }
    end

    # Categories present in the data but not in the vocabulary. These render
    # uncolored on the chart and are what the page's cleanup surface exists
    # to catch.
    def unknown_in_use
      used = ::ActionEvent.where(name: "Transaction").distinct.pluck(Arel.sql("data->>'category'"))
      used.compact.reject { |category| valid?(category) }
    end
  end
end
