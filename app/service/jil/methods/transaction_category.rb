# Jil bindings for the spending-category vocabulary.
#
# Exists so Jil tasks stop carrying their own copy of the list. Task 453
# ("Transaction Category Rules") and the task that builds the categorization
# Prompt both hardcoded all 22 names; either could drift from Rails and from
# each other, and only the data would show it.
#
#   categories = TransactionCategory.all()::Array
#   Prompt.create(... Questions: PromptQuestion.select("Category", categories))
#
# See ::TransactionCategory for the list itself.
class Jil::Methods::TransactionCategory < Jil::Methods::Base
  def cast(value)
    ::TransactionCategory.cast(value).to_s
  end

  # Alphabetical, matching every other place they are listed. Strings rather
  # than symbols because a Jil Array holds what a Prompt's choices need.
  def all
    ::TransactionCategory::ALL.map(&:to_s)
  end

  # { "eat out" => "#D95926", ... } — for anything that needs to color by
  # category without a second copy of the palette.
  def colors
    ::TransactionCategory::CATEGORIES.transform_keys(&:to_s)
  end

  # "" rather than a guess when the name is not in the vocabulary, so a typo
  # in a rule surfaces as an empty category instead of a plausible wrong one.
  # rubocop:disable Naming/PredicateMethod -- Jil method names cannot carry `?`
  def valid(category)
    ::TransactionCategory.valid?(category)
  end
  # rubocop:enable Naming/PredicateMethod

  def default
    ::TransactionCategory::DEFAULT.to_s
  end

  # The merchant rules, which task 453 held until 2026-08-12 and Rails owns
  # now. Task 454 is a one-line wrapper over this so `Custom.TransactionCategory`
  # keeps working for its callers.
  #
  # Falls back to "other" rather than "" deliberately: that IS what task 454
  # returned, and the value goes straight into a prompt a human is about to
  # confirm. `::TransactionCategory.for_merchant` answers nil for the unattended
  # callers, where a confident "other" would be worse than no answer.
  def match(merchant)
    ::TransactionCategory.for_merchant(merchant)&.to_s.presence || default
  end
end
