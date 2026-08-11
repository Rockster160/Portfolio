# The category vocabulary for spending.
#
# CAUTION — this is the fourth copy of this list, not the first. It also lives
# in:
#
#   * Jil task 453 "Transaction Category Rules", as the Keyval keys of the
#     merchant-pattern rules. That task is what actually auto-assigns a
#     category from a merchant string.
#   * The `choices` on the categorisation Prompt each Chase alert raises.
#   * CustomChart 4 "Transactions", as the keys of its colour map — a category
#     missing from there renders as an uncoloured series.
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

  class << self
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
    # uncoloured on the chart and are what the page's cleanup surface exists
    # to catch.
    def unknown_in_use
      used = ::ActionEvent.where(name: "Transaction").distinct.pluck(Arel.sql("data->>'category'"))
      used.compact.reject { |category| valid?(category) }
    end
  end
end
