class CreateLogTracker < ActiveRecord::Migration[5.0]
  def change
    add_column :users, :role, :integer, default: 0
    User.by_username("Rockster160")&.update(role: :admin)

    create_table :log_trackers do |t|
      t.string :user_agent
      t.string :ip_address
      t.string :http_method
      t.string :url
      t.string :params
      t.belongs_to :user

      t.timestamps
    end

    reversible do |migration|
      migration.up do
        log = File.read("log/custom_logger.txt")
        requests = log.split("\n\n\n")
        trackers = requests.map do |request|
          next unless request
          tracker = {}
          date_request, ip_str, user_str = request.split("\n").reject(&:blank?)
          date_str, http_method, param_str = date_request.split(" - ")
          url, *params = param_str.split(" ")
          tracker[:created_at] = DateTime.parse(date_str) rescue nil
          tracker[:http_method] = http_method
          # tracker[:user_agent] =
          tracker[:ip_address] = ip_str&.gsub("IP: ", "")
          tracker[:url] = url
          tracker[:params] = params&.join(" ")
          tracker[:user_id] = user_str&.split(":")&.first
          tracker
        end
        LogTracker.create(trackers)
      end
    end
  end
end
