# What the BROWSER is running, as opposed to what the server is.
#
# The byte service worker broadcasts `shell_updated` — which raises the reload
# prompt — when the shell it just re-fetched carries a different
# `<meta name="byte-version">` from the one it had cached. That meta used to be
# COMMIT_SHA, so every deploy changed it, and every deploy asked for a hard
# reload: a fix to a Jil task, a new spec, a Ruby service edit, none of which
# alter one byte of what the open page is running.
#
# The comparison was already trying to be this. Its comment says "compare deploy
# versions, not raw HTML", because the shell's bootstrap JSON differs on every
# request — right problem, wrong granularity. A deploy is not the unit; the
# client's own code is.
#
# So: a digest of the three things that decide what the browser has in memory.
#
#   * the fingerprinted asset URLs — the pipeline has already digested every
#     byte of JS and CSS into these, and they are literally what the page
#     fetches, so no globbing of sources can be more accurate
#   * the shell templates — the markup itself, plus the layout wrapping it
#   * the service worker — it decides what gets cached and served
#
# Change any of those and the open page is stale in a way only a reload fixes.
# Change anything else and it isn't.
module ByteShellVersion
  module_function

  # Resolved through the asset pipeline rather than read off disk: the URL is
  # what the browser actually requests, and its fingerprint already IS the
  # content digest.
  ASSETS = ["application.js", "application.css"].freeze

  # The shell's own markup. `byte/*` is the page (show plus the favicon and
  # kiosk partials it renders); then the layout wrapped around it, and every
  # layout PARTIAL — an allowlist by shape, since a partial could be rendered
  # into the shell but another top-level layout (jil, print, quick_actions)
  # never can. Over-including a partial costs a spurious prompt; missing one
  # leaves stale code running with no prompt at all, so the rule leans wide.
  TEMPLATES = [
    "app/views/byte/*.erb",
    "app/views/layouts/application.html.erb",
    "app/views/layouts/_*.erb",
  ].freeze

  WORKER = "public/byte_worker.js".freeze

  # Constant for the life of the process — a deploy restarts it, and nothing
  # short of a deploy changes any input.
  def current
    @current ||= compute
  end

  def reset!
    @current = nil
  end

  # Everything the digest is taken over, as plain strings. Split out from
  # `compute` so what counts as "the client's code" is inspectable — a test can
  # assert the shell markup really is in here, rather than trusting that a hash
  # changed for the reason it was supposed to.
  def parts
    list = ASSETS.map { |name| asset_fingerprint(name) }
    TEMPLATES.each { |glob|
      Rails.root.glob(glob).sort.each { |path|
        # The name as well as the body, so adding or removing a partial counts
        # even when the remaining files are untouched.
        list << path.basename.to_s
        list << path.read
      }
    }
    worker = Rails.root.join(WORKER)
    list << worker.read if worker.exist?
    list
  end

  def compute
    Digest::SHA256.hexdigest(parts.join("\n"))[0, 12]
  rescue StandardError => e
    # Never take the page down over a version string. Falling back to the commit
    # means the old behavior — a prompt on every deploy — which is noisy but
    # correct, rather than a constant, which would never prompt at all.
    Rails.logger.warn("[ByteShellVersion] falling back to COMMIT_SHA: #{e.class}: #{e.message}")
    COMMIT_SHA
  end

  def asset_fingerprint(name)
    ActionController::Base.helpers.asset_path(name)
  rescue StandardError
    # An unresolvable asset is not a reason to raise — the other inputs still
    # move. Named so it can't silently collide with a real path.
    "unresolved:#{name}"
  end
end
