# Jil bindings for the shared IconPool — emoji + Tabler icons search.
# Server-side counterpart to the in-page JS picker; both score against
# the same data files. See `IconPool` for the algorithm.
class Jil::Methods::Icon < Jil::Methods::Base
  def cast(value)
    value.to_s
  end

  # Icon.suggest("Brush teeth") → "🪥"  (or "" when nothing clears the
  # match floor). String return so it can drop straight into a Chore
  # icon field via interpolation or assignment.
  #
  # Searches the running user's household custom icons FIRST (so a
  # household-uploaded "Floss" beats the generic toothbrush), then the
  # global emoji + ti pool.
  def suggest(title)
    ::IconPool.best_match_value(title.to_s, for_household: @jil.user.chore_household).to_s
  end

  # Icon.search("brush") → Array of value strings (emoji chars, ti-*
  # class names, and/or data URLs for custom icons). Score-sorted,
  # custom/emoji-first on ties. Household-scoped to the running user.
  def search(query)
    ::IconPool.search(query.to_s, for_household: @jil.user.chore_household).map { |row| row[:c] }
  end
end
