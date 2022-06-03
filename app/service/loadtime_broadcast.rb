module LoadtimeBroadcast
  module_function

  def call(data=nil)
    if data.present?
      file = JSON.parse(File.read("loadtime.json") || "{}")
      data = file.merge(data)
      File.write("loadtime.json", data.to_json)
    else
      JSON.parse(File.read("loadtime.json") || "{}")
    end

    ActionCable.server.broadcast "loadtime_channel", data.deep_symbolize_keys
  end
end
