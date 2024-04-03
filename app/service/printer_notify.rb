module PrinterNotify
  module_function

  def notify(params)
    @params = params
    @fields = []

    # if @params[:topic] == "Print Progress"
    if @params[:topic] == "Print Started"
      return # no-op
    elsif @params[:topic] == "Print Done"
      push_to_slack(complete_attachment)
    else
      push_to_slack(fail_attachment)
    end
  end

  def message
    @params[:message]
  end

  def complete_attachment
    [
      {
        color: "#0E60ED",
        fields: build_complete_fields,
      }
    ]
  end

  def fail_attachment
    [
      {
        color: :danger,
        title: @params[:topic],
        fields: [
          { title: "Name", value: print_name, short: true },
          { title: "Progress", value: dig(:progress, :completion) || "", short: true },
        ]
      }
    ]
  end

  def build_complete_fields
    [
      { title: "Name",      value: print_name,           short: true },
      { title: "Time",      value: actual_complete_time, short: true },
      { title: "Cura Time", value: cura_est_time,        short: true },
      { title: "Octo Time", value: octo_est_time,        short: true },
    ]
  end

  def dig(*keys)
    obj = @params
    keys.each { |key|
      obj = obj.dig(key).then { |val|
        val.is_a?(String) && val.starts_with?("{") ? JSON.parse(val, symbolize_names: true) : val
      }
    }
    obj
  end

  def print_name
    full = dig(:extra, :name) || ""
    ext = full[/-?(\d+D)?(\d+H)?(\d+M)?.gcode/].to_s

    full[0..-ext.length - 1]
  end

  def actual_complete_time
    time = dig(:extra, :time) || ""

    sec_to_dur(time)
  end

  def octo_est_time
    time = dig(:job, :estimatedPrintTime) || ""

    sec_to_dur(time)
  end

  def cura_est_time
    str = dig(:extra, :name) || ""
    time = str[/-?(\d+D)?(\d+H)?(\d+M)?.gcode/].to_s[1..-7]

    str_to_dur(time)
  end

  def sec_to_dur(sec)
    Time.at(sec.to_i).utc.strftime "%H:%M:%S"
  end

  def str_to_dur(str)
    return "??" if str.blank?

    hours = str[/\d+D/].to_i * 24
    hours += str[/\d+H/].to_i
    minutes = str[/\d+M/].to_i

    [
      hours.to_s.rjust(2, "0"),
      minutes.to_s.rjust(2, "0")
    ].join(":") + ":00"
  end

  def push_to_slack attchs
    SlackNotifier.notify("*#{message}*", channel: '#portfolio', username: 'Printer-Bot', icon_emoji: ':printer:', attachments: attchs)
  end
end
