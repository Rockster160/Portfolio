module PrinterCommand
  module_function

  def command(msg)
    num = msg[/\d+/] || 10
    case msg
    when /\b(on|pre ?heat|heat)\b/
      PrinterApi.pre
      "Pre-heating your printer"
    when /\b(off|cool)\b/
      PrinterApi.cool
      "Cooling your printer"
    when /up and down/
      PrinterApi.move(z: num)
      PrinterApi.move(z: -num)
      "Moving the print head up and down #{num}mm"
    when /side to side/
      PrinterApi.move(x: num)
      PrinterApi.move(x: -num)
      "Moving the print head side to side #{num}mm"
    when /back and forth/
      PrinterApi.move(y: num)
      PrinterApi.move(y: -num)
      "Moving the print head back and forth #{num}mm"
    when /up/
      PrinterApi.move(z: num)
      "Moving the print head up #{num}mm"
    when /down/
      PrinterApi.move(z: -num)
      "Moving the print head down #{num}mm"
    when /left/
      PrinterApi.move(x: -num)
      "Moving the print head left #{num}mm"
    when /right/
      PrinterApi.move(x: num)
      "Moving the print head right #{num}mm"
    when /forward/
      PrinterApi.move(y: num)
      "Moving the print head forward #{num}mm"
    when /(backward|back)/
      PrinterApi.move(y: -num)
      "Moving the print head backward #{num}mm"
    when /(home)/
      PrinterApi.home
      "Homing printer head"
    when /(cancel|stop)/
      # PrinterApi.stop
      "Sorry, I don't know how to stop the printer yet."
    else
      "Don't know how to #{msg}"
    end
  end
end
