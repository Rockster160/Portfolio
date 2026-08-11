# The single source of truth for the spending-category vocabulary.
#
# It used to live in four places that had to be edited together — this module,
# Jil task 453's merchant rules, the `choices` on the categorization Prompt,
# and CustomChart 4's color map. Adding a category meant remembering all four,
# and `Extra Expense` is in the data exactly once because someone did not.
#
# Now Rails owns it and everything else derives: Jil reads it through
# `TransactionCategory.all()` / `.colors()` (see Jil::Methods::TransactionCategory)
# so the tasks no longer carry a copy, and the chart's color map is generated
# from `chart_color_config` rather than maintained alongside it.
module TransactionCategory
  # ONE hash: the category and the color it is drawn in. The list and the
  # palette are the same thing, so keeping them as separate constants meant
  # writing all 22 names twice and having no way to notice when they drifted.
  #
  # Alphabetical, and `ALL` re-sorts rather than trusting this to stay that
  # way — adding one in the wrong place should not reorder the UI.
  CATEGORIES = {
    alcohol:        "#CBB994",
    car:            "#8A6D3B",
    "card payment": "#6E7681",
    "eat out":      "#D95926",
    fun:            "#F5D67B",
    groceries:      "#3987E5",
    health:         "#59C26A",
    hobby:          "#45B6D4",
    home:           "#C98500",
    hosting:        "#A8E6CF",
    insurance:      "#DCA3B1",
    medical:        "#1DC91D",
    mortgage:       "#E66767",
    other:          "#AEB6C2",
    "pay check":    "#008300",
    people:         "#14C8B4",
    pets:           "#B07CC6",
    shopping:       "#D55181",
    subscriptions:  "#9085E9",
    taxes:          "#C91DC9",
    travel:         "#9EC91D",
    utilities:      "#199E70",
  }.freeze

  ALL = CATEGORIES.keys.sort_by(&:to_s).freeze
  DEFAULT = :other
  # Strays render in a neutral gray rather than borrowing a real category's
  # color, so "this is not a real category" is visible on the chart.
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

    def color(category)
      CATEGORIES[category.to_s.to_sym] || FALLBACK_COLOR
    end

    def valid?(category)
      CATEGORIES.key?(category.to_s.to_sym)
    end

    # Nil rather than DEFAULT on an unknown value: silently rewriting an
    # unrecognized category to "other" would erase the fact that something
    # wrote a category nothing knows about. `Extra Expense` is in the data
    # exactly once for that reason.
    def cast(category)
      ALL.detect { |known| known.to_s == category.to_s }
    end

    # The color map in the exact shape CustomChart 4's config expects, so the
    # chart is GENERATED from this rather than kept in step with it by hand.
    def chart_color_config
      ALL.map { |category| "#{category} = #{CATEGORIES[category]}" }.join("\n")
    end

    # Categories present in the data but outside the vocabulary. These render
    # uncolored on the chart and are what the banking page's cleanup surface
    # exists to catch.
    def unknown_in_use
      used = ::ActionEvent.where(name: "Transaction").distinct.pluck(Arel.sql("data->>'category'"))
      used.compact.reject { |category| valid?(category) }
    end
  end
end
