module LoadtimeBroadcast
  module_function

  def call(data=nil)
    if data.present?
      data = loadtime_data.merge(data)
      File.write("loadtime.json", data.to_json)
    else
      data = loadtime_data
    end

    data.transform_values! { |d| d.merge timestamp: Time.current.to_i }

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
