RSpec.describe "Travel Command Jil code" do
  it "passes Jil validation" do
    code = <<~'JIL'
      data = Global.input_data()::Hash
      captures = data.get("named_captures")::Hash
      rawCommand = captures.get("command")::String
      preamble = captures.get("preamble")::String
      suffix = captures.get("suffix")::String
      command = String.new("#{rawCommand}")::String
      q0996 = Global.if({
        b7a21 = suffix.presence()::Boolean
      }, {
        c7a22 = String.new("#{preamble} to #{suffix}")::String
        d7a23 = Global.set!("command", c7a22)::Any
      }, {})::Any
      rawDirection = captures.get("direction")::String
      direction = String.new("arrive")::String
      e7a24 = Global.if({
        f7a25 = rawDirection.match("/leave|depart|head/")::Boolean
      }, {
        g7a26 = Global.set!("direction", "depart")::Any
      }, {})::Any
      rawDest = captures.get("destination")::String
      lowerDest = rawDest.format("lower")::String
      cleanDest = lowerDest.replace("'s", "")::String
      noBack = cleanDest.replace("/^back to /", "")::String
      destination = noBack.replace("/^(back|back home)$/", "home")::String
      stored = Global.get_cache("ArrivalCommands", "")::Hash
      dirCmds = stored.get(direction)::Hash
      destCmds = dirCmds.get(destination)::Array
      h7a27 = destCmds.push!(command)::Array
      i7a28 = dirCmds.set!(destination, destCmds)::Hash
      j7a29 = stored.set!(direction, dirCmds)::Hash
      *k7a30 = Global.set_cache("ArrivalCommands", "", stored)::Any
      reverseCmd = command.replace("/\\bme\\b/", "you")::String
      msg = Text.new("Okay, I'll #{reverseCmd} when you #{direction} #{destination}.")::String
      l7a31 = Global.return(msg)::Any
    JIL

    expect { Jil::Validator.validate!(code) }.not_to raise_error
  end
end
