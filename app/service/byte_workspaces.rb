# The directories a Claude or shell conversation can start in.
#
# Rails runs on a server and the code lives on the Mac, so Rails cannot look at
# the filesystem it's offering to pick from. The Mac reports its list instead
# (POST /webhooks/byte/workspaces, on boot and hourly) and this caches it.
#
# Cached rather than fetched live for the reason the picker exists at all: the
# Mac sleeps. A new conversation started from a phone at midnight still needs to
# be able to say "start this one in ocs-backend", and asking a sleeping laptop
# would fail exactly when it's least convenient. A directory list goes stale
# slowly and harmlessly — the worst case is a repo cloned an hour ago not being
# offered yet, and typing the path by hand still works.
module ByteWorkspaces
  module_function

  KEY   = :byte_workspaces
  LIMIT = 300

  # Where a conversation starts when nobody said. Matches the Mac's own
  # State::DEFAULT_CWD; a mismatch would mean the picker showed one thing and
  # the shell opened somewhere else.
  DEFAULT = "~/code/Portfolio".freeze

  def all
    stored = DataStorage[KEY]
    return [] unless stored.is_a?(Hash)

    Array(stored["paths"] || stored[:paths])
  end

  def reported_at
    stored = DataStorage[KEY]
    return nil unless stored.is_a?(Hash)

    Time.zone.parse((stored["reported_at"] || stored[:reported_at]).to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def replace!(paths)
    cleaned = Array(paths).map { |p| tidy(p) }.compact_blank.uniq.sort_by(&:downcase).first(LIMIT)
    DataStorage[KEY] = { "paths" => cleaned, "reported_at" => Time.current.iso8601 }
    cleaned
  end

  # Ranked so the thing being typed lands first: an exact basename beats a
  # basename that starts with the query, which beats a match anywhere in the
  # path. Typing "ocs" should offer `~/code/ocs-backend` before
  # `~/code/ocs-backend--rn-feature-appraisal-denied-email-spec`, and a plain
  # alphabetical sort puts the worktree first every time.
  def search(query, limit: 20)
    needle = query.to_s.strip.downcase
    return all.first(limit) if needle.empty?

    all.select { |p| p.downcase.include?(needle) }
      .sort_by { |p| [rank(p, needle), p.length, p.downcase] }
      .first(limit)
  end

  def rank(path, needle)
    base = File.basename(path).downcase
    return 0 if base == needle
    return 1 if base.start_with?(needle)
    return 2 if base.include?(needle)

    3
  end

  # `~` is kept rather than expanded: the server's home directory is not the
  # Mac's, and a path expanded here would be wrong there.
  def tidy(path)
    text = path.to_s.strip
    return nil if text.empty?

    text.sub(%r{/+\z}, "")
  end

  # Somewhere a conversation could plausibly start. Deliberately permissive
  # about paths not in the index — a repo cloned since the last report is real
  # even though we've never heard of it — and only rejects the shapes that
  # can't be a directory at all.
  def plausible?(path)
    text = tidy(path)
    return false if text.blank?
    return false unless text.start_with?("~/", "/")
    return false if text.include?("..")

    true
  end
end
