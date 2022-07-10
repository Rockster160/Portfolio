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
      Printer.move(z: num)
      Printer.move(z: -num)
      "Moving the print head up and down #{num}mm"
    when /side to side/
      Printer.move(x: num)
      Printer.move(x: -num)
      "Moving the print head side to side #{num}mm"
    when /back and forth/
      Printer.move(y: num)
      Printer.move(y: -num)
      "Moving the print head back and forth #{num}mm"
    when /up/
      Printer.move(z: num)
      "Moving the print head up #{num}mm"
    when /down/
      Printer.move(z: -num)
      "Moving the print head down #{num}mm"
    when /left/
      Printer.move(x: -num)
      "Moving the print head left #{num}mm"
    when /right/
      Printer.move(x: num)
      "Moving the print head right #{num}mm"
    when /forward/
      Printer.move(y: num)
      "Moving the print head forward #{num}mm"
    when /(backward|back)/
      Printer.move(y: -num)
      "Moving the print head backward #{num}mm"
    when /(home)/
      Printer.home
      "Homing printer head"
    when /(cancel|stop)/
      # Printer.stop
      "Sorry, I don't know how to stop the printer yet."
    else
      "Don't know how to #{msg}"
    end
  end
end
