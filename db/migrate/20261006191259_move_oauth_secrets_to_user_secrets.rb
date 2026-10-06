# Oauth::Base now reads and writes these four fields through the user's
# encrypted secrets, so they move out of the plain-JSON oauth cache at the same
# deploy — there is no stretch where the code looks in the new place and finds
# nothing.
class MoveOauthSecretsToUserSecrets < ActiveRecord::Migration[7.1]
  FIELDS = ["client_secret", "access_token", "refresh_token", "id_token"].freeze

  # Pinned here so the move keeps working however the app's model changes.
  class Secret < ActiveRecord::Base
    self.table_name = "user_secrets"
    encrypts :value
  end

  def up
    UserCache.where(key: :oauth).find_each { |cache|
      next unless cache.data.is_a?(Hash)

      data = cache.data.deep_stringify_keys
      data.each { |service, fields|
        next unless fields.is_a?(Hash)

        FIELDS.each { |field|
          value = fields.delete(field)
          next if value.blank?

          secret = Secret.find_or_initialize_by(user_id: cache.user_id, name: "oauth:#{service}:#{field}")
          secret.update!(value: value) if secret.new_record?
        }
      }
      cache.update!(data: data) if data != cache.data.deep_stringify_keys
    }
  end

  def down
    Secret.where("name LIKE 'oauth:%'").find_each { |secret|
      _, service, field = secret.name.split(":", 3)
      cache = UserCache.find_or_create_by!(user_id: secret.user_id, key: :oauth)
      data = (cache.data.is_a?(Hash) ? cache.data : {}).deep_stringify_keys
      (data[service] ||= {})[field] = secret.value
      cache.update!(data: data)
      secret.destroy!
    }
  end
end
