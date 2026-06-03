module IconPool
  # ============================================================================
  # MIRRORED in JavaScript at `app/views/chores/_page_script.html.erb`
  # (search for `const IconPool`). The two implementations share the same
  # data files (`public/emoji_index.json`, `public/icons_index.json`) AND
  # the same algorithm. If you change any of:
  #
  #   * scoring tiers (`score_one`)
  #   * query passes / tokenization (`query_passes`)
  #   * normalization (`normalize`)
  #   * variant expansion (`variants`)
  #   * irregular-plural map (`IRREGULARS`)
  #   * stop words (`STOPWORDS`)
  #   * minimum match floor (`MIN_SCORE`)
  #
  # …port the same change to the JS file in the same commit. Otherwise
  # server-side suggestion (Jil `Icon.suggest`, etc.) and client-side
  # suggestion (chore-modal title input) will drift apart.
  # ============================================================================

  module_function

  EMOJI_PATH = Rails.root.join("public/emoji_index.json").freeze
  ICONS_PATH = Rails.root.join("public/icons_index.json").freeze

  # Score tiers — see comment block in `score_one` for the contract.
  MIN_SCORE = 3

  # English irregular plurals — bidirectional so "teeth" → "tooth" AND
  # "tooth" → "teeth" both produce the partner form during variant
  # generation. Keep in sync with the JS `IRREGULARS` map.
  IRREGULARS = {
    "teeth"    => "tooth",
    "mice"     => "mouse",
    "geese"    => "goose",
    "feet"     => "foot",
    "knives"   => "knife",
    "leaves"   => "leaf",
    "lives"    => "life",
    "loaves"   => "loaf",
    "wolves"   => "wolf",
    "shelves"  => "shelf",
    "men"      => "man",
    "women"    => "woman",
    "children" => "child",
    "oxen"     => "ox",
    "people"   => "person",
    "cacti"    => "cactus",
  }.freeze
  IRREGULAR_INV = IRREGULARS.invert.freeze

  STOPWORDS = Set.new(%w[
    the a an and or to of in on at
    for with from by is are was were be
    do does did out off up down
    my your our this that these those
  ]).freeze

  # Lazy-loaded, process-cached pool. Each row is the canonical
  # shape: { c:, n:, k:, nn:, nk:, kind: } — `nn` / `nk` are
  # pre-normalized so per-search cost stays low.
  def pool
    @pool ||= load_pool
  end

  # Drop the cache — useful in tests after rebuilding index files.
  def reset!
    @pool = nil
  end

  def load_pool
    emoji = load_index(EMOJI_PATH).map { |row| tag_row(row, :emoji) }
    icons = load_index(ICONS_PATH).map { |row| tag_row(row, :ti) }
    # Emoji-first concat so default-order tiebreak prefers emoji.
    emoji + icons
  end

  def load_index(path)
    return [] unless File.exist?(path)

    JSON.parse(File.read(path))
  end

  def tag_row(row, kind)
    {
      c:    row["c"],
      n:    row["n"],
      k:    row["k"] || [],
      nn:   normalize(row["n"].to_s),
      nk:   (row["k"] || []).map { |k| normalize(k.to_s) },
      kind: kind,
    }
  end

  def normalize(query)
    query.to_s.downcase.gsub(/[\s\-_:]+/, "")
  end

  # Generate the set of forms to try against the keyword index. Three
  # buckets:
  #   * irregular plurals (bidirectional, hard-coded list)
  #   * regular plural suffix stripping / adding
  #   * verb-form gerund/past-tense stripping so "loading" reaches
  #     icons whose keyword is "load", "saving" reaches "save", etc.
  def variants(q)
    set = Set.new([q])
    set << IRREGULARS[q]    if IRREGULARS.key?(q)
    set << IRREGULAR_INV[q] if IRREGULAR_INV.key?(q)

    # Plural variants
    set << "#{q[0..-4]}y" if q.end_with?("ies") && q.length > 4
    set << q[0..-3]       if q.end_with?("es")  && q.length > 3
    set << q[0..-2]       if q.end_with?("s")   && q.length > 2
    if q.length >= 3
      set << "#{q}s"
      set << "#{q}es"
    end

    # Verb forms — strip -ing / -ed both with and without restoring a
    # trailing "e" so "loading" → "load" AND "saving" → "save" both work.
    # And the inverse, so a "save" query reaches an icon indexed only
    # as "saving".
    if q.end_with?("ing") && q.length > 4
      base = q[0..-4]
      set << base                  # loading → load
      set << "#{base}e"            # saving  → save
    end
    if q.end_with?("ed") && q.length > 3
      set << q[0..-3]              # loaded → load
      set << q[0..-2]              # loved  → love
    end
    if q.length >= 3
      set << "#{q}ing"             # load → loading
      set << "#{q[0..-2]}ing" if q.end_with?("e")  # save → saving
      set << "#{q}ed"              # load → loaded
      set << "#{q}d"   if q.end_with?("e")          # save → saved
    end

    set.to_a
  end

  # Score one (normalized) row name + keyword list against one
  # (normalized) query string.
  #
  # Base tiers:
  #   5.5 — exact match on name           (strongest)
  #   4.x — exact match on a keyword
  #   3.5 — prefix match on name
  #   3.x — prefix match on a keyword
  #   2.5 — substring match on name
  #   2.x — substring match on a keyword
  #   0   — no match
  #
  # Keyword matches add a positional bonus (`0.49 / (1 + index)`) so an
  # alias listed earlier in the `k` array signals "more primary" and
  # tiebreaks above the same match at a later index. 0.49 keeps each
  # tier strictly below the next one above.
  def score_one(name, keys, q)
    return 5.5 if name == q

    best = 0.0
    if name.start_with?(q)
      best = 3.5
    elsif name.include?(q)
      best = 2.5
    end
    keys.each_with_index do |k, i|
      pos = 0.49 / (1 + i)
      if k == q
        v = 4 + pos
        return v > best ? v : best
      end
      if k.start_with?(q)
        v = 3 + pos
        best = v if v > best
      elsif k.include?(q)
        v = 2 + pos
        best = v if v > best
      end
    end
    best
  end

  # Best score for ONE pass — takes that pass's expanded variants.
  def score_row(row, variants_for_pass)
    best = 0.0
    variants_for_pass.each do |v|
      s = score_one(row[:nn], row[:nk], v)
      best = s if s > best
      break if best >= 5.5 # max possible — exact-name match
    end
    best
  end

  # Sum per-pass scores, multiplying each by its positional weight so
  # later tokens carry more weight (the subject of a chore tends to
  # come at the end: "Water Flowers" → flowers is the subject).
  def sum_score(row, variant_sets_with_weights)
    total = 0
    variant_sets_with_weights.each do |vs, w|
      total += w * score_row(row, vs)
    end
    total
  end

  # Break a free-text query into [pass_string, weight] pairs:
  #   * full normalized pass (weight = number of tokens, min 1) — so
  #     multi-word phrases that prefix-match a compound still rank.
  #   * each non-stopword token in position order, weight = 1-indexed
  #     position. Last token wins ties between competing single-word
  #     matches.
  def query_passes(query)
    raw = query.to_s.downcase.strip
    return [] if raw.empty?

    full = normalize(raw)
    tokens = raw.split(/[^a-z0-9]+/).reject { |t| t.empty? || STOPWORDS.include?(t) }
    full_weight = [tokens.size, 1].max
    passes = []
    passes << [full, full_weight] if full.length >= 2
    tokens.each_with_index do |t, i|
      next if t.length < 2 || t == full

      passes << [t, i + 1]
    end
    passes
  end

  def expand_passes(passes)
    passes.map { |p, w| [variants(p), w] }
  end

  # Per-household custom icons are merged in ahead of the global pool
  # when `for_household:` is provided — they win ties since users care
  # about their own icons before generic emoji. Built fresh each call
  # (no per-process cache) since admin/edits invalidate.
  def pool_for(household)
    return pool if household.nil?

    household.icons.ordered.map { |i| tag_row(i.as_pool_row.stringify_keys, :custom) } + pool
  end

  # Score-sorted search over the (optionally household-scoped) pool.
  # Empty / pass-less query returns the pool in native order.
  def search(query, limit: nil, for_household: nil)
    src = pool_for(for_household)
    passes = query_passes(query)
    if passes.empty?
      return limit ? src.first(limit) : src.dup
    end

    variant_sets = expand_passes(passes)
    scored = []
    src.each_with_index do |row, i|
      total = sum_score(row, variant_sets)
      scored << [total, i, row] if total.positive?
    end
    scored.sort_by! { |s, i, _| [-s, i] }
    sliced = limit ? scored.first(limit) : scored
    sliced.map { |_, _, row| row }
  end

  # Highest-scoring candidate, or nil when no candidate clears the
  # MIN_SCORE floor (one prefix match).
  def best_match(query, for_household: nil)
    src = pool_for(for_household)
    passes = query_passes(query)
    return nil if passes.empty?

    variant_sets = expand_passes(passes)
    best_row = nil
    best_score = 0
    src.each do |row|
      total = sum_score(row, variant_sets)
      if total > best_score
        best_score = total
        best_row = row
      end
    end
    best_score >= MIN_SCORE ? best_row : nil
  end

  # Convenience for the common "I just want the emoji/class/data-URL
  # string" caller — used by Jil method bindings.
  def best_match_value(query, for_household: nil)
    best_match(query, for_household: for_household)&.dig(:c)
  end
end
