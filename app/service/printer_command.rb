module PrinterCommand
  module_function

  def command(msg)
    num = msg[/\d+/] || 10
    case msg
    when /\b(on|pre ?heat|heat|start)\b/
      PrinterAPI.pre
      "Pre-heating your printer"
    when /\b(off|cool)\b/
      PrinterAPI.cool
      "Cooling your printer"
    when /up and down/
      PrinterAPI.move(z: num)
      PrinterAPI.move(z: -num)
      "Moving the print head up and down #{num}mm"
    when /side to side/
      PrinterAPI.move(x: num)
      PrinterAPI.move(x: -num)
      "Moving the print head side to side #{num}mm"
    when /back and forth/
      PrinterAPI.move(y: num)
      PrinterAPI.move(y: -num)
      "Moving the print head back and forth #{num}mm"
    when /up/
      PrinterAPI.move(z: num)
      "Moving the print head up #{num}mm"
    when /down/
      PrinterAPI.move(z: -num)
      "Moving the print head down #{num}mm"
    when /left/
      PrinterAPI.move(x: -num)
      "Moving the print head left #{num}mm"
    when /right/
      PrinterAPI.move(x: num)
      "Moving the print head right #{num}mm"
    when /forward/
      PrinterAPI.move(y: num)
      "Moving the print head forward #{num}mm"
    when /(backward|back)/
      PrinterAPI.move(y: -num)
      "Moving the print head backward #{num}mm"
    when /(home)/
      PrinterAPI.home
      "Homing printer head"
    when /(cancel|stop)/
      # PrinterAPI.stop
      "Sorry, I don't know how to stop the printer yet."
    else
      "Don't know how to #{msg}"
    end
  end
end
