class LoadtimeBroadcast
  module_function

  def call(data=nil)
    if data.present?
      File.write("loadtime.json", data.to_json)
    else
      data = JSON.parse(File.read("loadtime.json"))
    end

    ActionCable.server.broadcast "loadtime_channel", data.deep_symbolize_keys
  end
end
