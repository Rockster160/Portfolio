class NestCommand
  def self.command(settings)
    new.command(settings)
  end

  def command(settings)
    return unless Rails.env.production? || Rails.env.test?

    ActionCable.server.broadcast(:nest_channel, { loading: true })
    get_devices if DataStorage[:nest_devices].blank?

    settings = settings.to_s.squish.downcase

    device_name = "Upstairs" if settings.match?(/(up|rooms)/i)
    device_name ||= "Entryway"

    device_data = (DataStorage[:nest_devices] || {})[device_name.to_sym]

    device = GoogleNestDevice.new(nil, device_data)

    @mode = nil
    @temp = nil
    @mode = :heat if settings.match?(/\b(heat)\b/i)
    @mode = :cool if settings.match?(/\b(cool)\b/i)
    device.mode = @mode if @mode
    @temp = settings[/\b\d+\b/].to_i if settings.match?(/\b\d+\b/)
    device.temp = settings[/\b\d+\b/].to_i if @temp

    get_devices

    if @mode.present? && @temp.present?
      "Set house #{device_name.downcase} #{@mode == :cool ? "AC" : "heat"} to #{@temp}°."
    elsif @mode.present? && @temp.blank?
      "Set house #{device_name.downcase} to #{@mode}."
    elsif @mode.blank? && @temp.present?
      "Set house #{device_name.downcase} to #{@temp}°."
    end
  rescue StandardError => e
    ActionCable.server.broadcast(:nest_channel, { failed: true })
    if e.message == "400 Bad Request"
      RefreshNestMessageWorker.perform_async
    else
      backtrace = e.backtrace.map { |l|
        l.include?("/app/") ? l.gsub("`", "'").gsub(/^.*\/app\//, "") : nil
      }.compact.join("\n").truncate(2000)
      SlackNotifier.notify("Failed to set Nest: #{e.inspect}\n```\n#{backtrace}\n```")
    end
  end

  def get_devices
    subscription ||= GoogleNestControl.new
    ActionCable.server.broadcast(:nest_channel, { devices: subscription.devices.map(&:to_json) })
  end
end
