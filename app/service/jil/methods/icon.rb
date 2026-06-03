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
  def suggest(title)
    ::IconPool.best_match_value(title.to_s).to_s
  end

  # Icon.search("brush") → Array of value strings (emoji chars and/or
  # `ti-*` class names), score-sorted, emoji-first on ties. Caller can
  # truncate as needed.
  def search(query)
    ::IconPool.search(query.to_s).map { |row| row[:c] }
  end
end
