class MeCache
  def self.get(key)
    User.me.caches.get(key)
  end

  def self.set(key, val)
    User.me.caches.set(key, val)
  end
end
