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

  # Generate the set of forms to try against the keyword index so
  # "teeth" reaches "toothbrush" via "tooth" (which prefix-matches
  # the compound), and regular plurals fold both directions.
  def variants(q)
    set = Set.new([q])
    set << IRREGULARS[q] if IRREGULARS.key?(q)
    set << IRREGULAR_INV[q] if IRREGULAR_INV.key?(q)
    set << "#{q[0..-4]}y" if q.end_with?("ies") && q.length > 4
    set << q[0..-3]       if q.end_with?("es")  && q.length > 3
    set << q[0..-2]       if q.end_with?("s")   && q.length > 2
    if q.length >= 3
      set << "#{q}s"
      set << "#{q}es"
    end
    set.to_a
  end

  # Score one (normalized) row name + keyword list against one
  # (normalized) query string.
  #
  #   5 — exact match on name           (strongest)
  #   4 — exact match on a keyword
  #   3 — prefix match on name or key
  #   2 — substring match on name or key
  #   0 — no match
  def score_one(name, keys, q)
    return 5 if name == q

    best = 0
    if name.start_with?(q)
      best = 3
    elsif name.include?(q)
      best = 2
    end
    keys.each do |k|
      return 4 if k == q       # beats any name-prefix
      if best < 3 && k.start_with?(q)
        best = 3
      elsif best < 2 && k.include?(q)
        best = 2
      end
    end
    best
  end

  # Best score for ONE pass — takes that pass's expanded variants.
  def score_row(row, variants_for_pass)
    best = 0
    variants_for_pass.each do |v|
      s = score_one(row[:nn], row[:nk], v)
      best = s if s > best
      break if best == 5
    end
    best
  end

  def sum_score(row, variant_sets)
    variant_sets.sum { |vs| score_row(row, vs) }
  end

  # Break a free-text query into the scoring passes used by both
  # search AND best_match.
  def query_passes(query)
    raw = query.to_s.downcase.strip
    return [] if raw.empty?

    full = normalize(raw)
    tokens = raw.split(/[^a-z0-9]+/).reject { |t| t.empty? || STOPWORDS.include?(t) }
    passes = []
    passes << full if full.length >= 2
    tokens.each { |t| passes << t if t.length >= 2 && t != full }
    passes
  end

  # Score-sorted search over the full pool. Empty / pass-less query
  # returns the pool in its native (emoji-first) order. Returns an
  # array of row hashes.
  def search(query, limit: nil)
    passes = query_passes(query)
    if passes.empty?
      return limit ? pool.first(limit) : pool.dup
    end

    variant_sets = passes.map { |p| variants(p) }
    scored = []
    pool.each_with_index do |row, i|
      total = sum_score(row, variant_sets)
      scored << [total, i, row] if total.positive?
    end
    # Score desc; index asc tiebreaks so emoji beat ti at equal score.
    scored.sort_by! { |s, i, _| [-s, i] }
    sliced = limit ? scored.first(limit) : scored
    sliced.map { |_, _, row| row }
  end

  # Highest-scoring candidate, or nil when no candidate clears the
  # MIN_SCORE floor (one prefix match).
  def best_match(query)
    passes = query_passes(query)
    return nil if passes.empty?

    variant_sets = passes.map { |p| variants(p) }
    best_row = nil
    best_score = 0
    pool.each do |row|
      total = sum_score(row, variant_sets)
      if total > best_score
        best_score = total
        best_row = row
      end
    end
    best_score >= MIN_SCORE ? best_row : nil
  end

  # Convenience for the common "I just want the emoji/class string"
  # caller — used by Jil method bindings.
  def best_match_value(query)
    best_match(query)&.dig(:c)
  end
end
