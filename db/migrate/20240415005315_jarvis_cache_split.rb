class JarvisCacheSplit < ActiveRecord::Migration[7.1]
  def up
    JarvisCache.where(key: nil).find_each do |cache|
      cache.data.each do |key, data|
        cache.user.jarvis_caches.find_or_create_by(key: key).update(data: data)
      end
    end
  end
end
