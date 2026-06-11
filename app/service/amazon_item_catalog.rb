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

  def self.all
    MeCache.get(CACHE_KEY) || {}
  end

  def self.get(asin)
    return nil if asin.blank?

    all[asin.to_s]
  end

  def self.set(asin, name: nil, listed_name: nil, full_name: nil)
    return if asin.blank?

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
