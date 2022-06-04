module LoadtimeBroadcast
  module_function

  def call(data=nil)
    if data.present?
      file = loadtime_data
      data = file.merge(data)
      File.write("loadtime.json", data.to_json)
    else
      data = loadtime_data
    end

    ActionCable.server.broadcast "loadtime_channel", data.deep_symbolize_keys
  end

  def loadtime_data
    @loadtime_data = begin
      JSON.parse(File.read("loadtime.json") || "{}")
    rescue
      {}
    end
  end
end
