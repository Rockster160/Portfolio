class MeCache
  def self.get(key)
    User.me.jarvis_caches.get(key)
  end

  def self.set(key, val)
    User.me.jarvis_caches.set(key, val)
  end
end
