class SummonersWarsController < ApplicationController
  def show
    # Should probably be searchable
    @monsters = Monster.where.not(name: nil).order(:name)
  end

  def runes
    mapping_url = "https://raw.githubusercontent.com/Xzandro/sw-exporter/master/app/mapping.js"
    mapping_json = HTTParty.get(mapping_url)
    @mapping = mapping_json.gsub("module.exports = ", "")

    player_file = "/Users/rocconicholls/Library/Group Containers/3L68KQB4HG.group.com.readdle.smartemail/databases/messagesData/1/8527/カタクリの-19659337.json"
    json = JSON.parse(File.read(player_file)).deep_symbolize_keys
    @player_data = json
  end
end
