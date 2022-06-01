$(document).ready(function() {
  if ($(".ctr-gcode_splitter.act-index").length == 0) { return }
  var gcodes = {}
  var error = undefined

  function GcodeFile(file, text) {
    if (file) {
      this.file = file
      this.name = file.name
      this.size = file.size
    }

    this.text = text
  }

  GcodeFile.prototype.zLines = function() {
    return this.text.match(/^G0.*Z\d.*?$/gm)
  }

  GcodeFile.prototype.finalZLine = function() {
    var zChanges = this.zLines()

    return zChanges[zChanges.length - 1]
  }

  GcodeFile.prototype.nextZLine = function(prevZ) {
    var zChanges = this.zLines()

    return zChanges.find(function(line) {
      var zVal = parseFloat(line.match(/(?:Z)(\d.*?$)/)[1])
      return zVal > prevZ
    })
  }

  GcodeFile.compare = function() {
    var left = gcodes["full_file"]
    var right = gcodes["base_file"]

    if (left == undefined || right == undefined) { return error = "Need both files in order to compare." }
    if (left.size == right.size) { return error = "Files are same size. No split found." }

    if (left.size > right.size) {
      var base = right
      var full = left
    } else if (left.size < right.size) {
      var base = left
      var full = right
    }

    var baseFinalZ = base.finalZLine()
    var zVal = parseFloat(baseFinalZ.match(/(?:Z)(\d.*?$)/)[1])
    console.log("Base: ", baseFinalZ);
    if (isNaN(zVal)) { return error = "No Z-line found in base." }

    var splitLine = full.nextZLine(zVal)
    console.log("Full: ", splitLine);
    if (!splitLine) { return error = "No Z-line found beyond base." }

    var fullText = full.text
    var splitIdx = fullText.indexOf(splitLine)
    var pauseLine = "M600 B10 X10 Y15 Z5 ; Do filament change at X:10, Y:15 and Z:+5 from current\n"

    var newText = [fullText.slice(0, splitIdx), pauseLine, fullText.slice(splitIdx)].join('')

    var output_file = {
      name: "multicolor-" + full.name,
      size: newText.length,
    }

    return new GcodeFile(output_file, newText)
  }

  GcodeFile.generate = function() {
    gcodes["output"] = GcodeFile.compare()

    if (error) {
      $(".output").addClass("error").text(error)
      error = undefined
    } else {
      $(".output").removeClass("error").text(gcodes["output"].text)
    }
  }

  function download(filename, text) {
    var element = document.createElement("a");
    element.setAttribute("href", "data:text/plain;charset=utf-8," + encodeURIComponent(text));
    element.setAttribute("download", filename);

    element.style.display = "none";
    document.body.appendChild(element);

    element.click();

    document.body.removeChild(element);
  }

  $(document).on("drop", ".drop-zone", function(evt) {
    var $zone = $(this)
    var dataTransfer = evt.originalEvent.dataTransfer

    // Prevent default behavior (Prevent file from being opened)
    evt.preventDefault()

    if (dataTransfer.items) {
      // Use DataTransferItemList interface to access the file(s)
      for (var i = 0; i < dataTransfer.items.length; i++) {
        // If dropped items aren't files, reject them
        if (dataTransfer.items[i].kind === "file") {
          var file = dataTransfer.items[i].getAsFile()
          file.text().then(function(text) {
            gcodes[$zone.prop("id")] = new GcodeFile(file, text)
            $zone.text(text)
            $zone.css("font-size", "8px")
          })
          console.log("file.name = " + file.name)
        }
      }
    } else {
      // Use DataTransfer interface to access the file(s)
      for (var i = 0; i < dataTransfer.files.length; i++) {
        console.log("... file[" + i + "].name = " + dataTransfer.files[i].name)
      }
    }
  })

  $(document).on("dragover", ".drop-zone", function(evt) {
    // Prevent default behavior (Prevent file from being opened)
    evt.preventDefault()
  })

  $(document).on("click", "[name=download]", function(evt) {
    var file = gcodes["output"]
    download(file.name, file.text)
  })

  $(document).on("click", "[name=compare]", function(evt) {
    GcodeFile.generate()
    $("[name=download]").prop("disabled", $(".output").hasClass("error"))
  })
})
