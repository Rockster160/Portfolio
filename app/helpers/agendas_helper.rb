module AgendasHelper
  def location_is_url?(text)
    text.to_s.strip.match?(%r{\Ahttps?://}i)
  end

  # Cache key the agenda service worker stamps into its CACHE_NAME. Any
  # change to the bundle / shell URLs flips this digest, which makes the
  # SW activate handler delete the old cache and re-precache. Falls back
  # to the deploy timestamp in dev so iterating on the SW gives a fresh
  # cache on every reload.
  # Manual epoch knob — bump to force every installed agenda PWA to
  # activate a fresh SW + re-cache its shells on next page load. Use for
  # changes that don't naturally bump asset digests (server-side
  # behavior, shell-inline script edits served by ERB partials) but
  # still need to invalidate existing client caches.
  SW_CACHE_EPOCH = 1

  def sw_cache_version
    parts = [
      SW_CACHE_EPOCH.to_s,
      Rails.application.config.assets.version.to_s,
      safe_asset_digest("application.js"),
      safe_asset_digest("application.css"),
    ]
    digest = Digest::SHA1.hexdigest(parts.compact.join("|"))[0, 12]
    Rails.env.development? ? "dev-#{Time.current.to_i}" : digest
  end

  private

  def safe_asset_digest(path)
    asset_path(path)
  rescue StandardError
    nil
  end
end
