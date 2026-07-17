# Per-ASIN cache of resolved product names. Lets repeat orders of the same SKU
# reuse a previously-resolved short name (from ChatGPT or a manual rename) so we
# don't re-call the API and so user renames stick across future orders.
#
# Backed by MeCache, keyed by ASIN:
#   {
#     "B000T9YBT8" => { name: "Sprite", listed_name: "Sprite Zero, 12 fl oz, 12 Pack", full_name: "..." },
#     ...
#   }
class AmazonItemCatalog
  CACHE_KEY = :amazon_item_catalog
  # Amazon ASINs are 10 alphanumeric chars starting with a letter (usually B0…).
  # Placeholder rows use their order_id as item_id (`\d{3}-\d{7}-\d{7}`) and
  # manually-added items use `CUSTOM-…` - neither belongs in the per-SKU cache.
  ASIN_KEY_REGEX = /\A[A-Z0-9]{10,}\z/i

  def self.asin?(key)
    key.to_s.match?(ASIN_KEY_REGEX)
  end

  def self.all
    # MeCache backs to a JSONB column via SafeJsonSerializer, which symbolizes
    # every parsed key. The catalog's outer keys are ASINs (e.g. "B0FDLFSZ1S")
    # which come back as symbols after a round-trip - normalize to strings so
    # get/set lookups by ASIN work consistently before and after persistence.
    (MeCache.get(CACHE_KEY) || {}).transform_keys(&:to_s)
  end

  def self.get(asin)
    return nil if asin.blank?

    all[asin.to_s]
  end

  def self.set(asin, name: nil, listed_name: nil, full_name: nil)
    return if asin.blank?
    return unless asin?(asin)

    catalog = all
    entry = catalog[asin.to_s] || {}
    entry[:name]        = name.to_s        if name.present?
    entry[:listed_name] = listed_name.to_s if listed_name.present?
    entry[:full_name]   = full_name.to_s   if full_name.present?
    catalog[asin.to_s] = entry
    MeCache.set(CACHE_KEY, catalog)
    entry
  end
end
