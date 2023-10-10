$(document).ready(function() {
  if ($(".ctr-pages.act-edit, .ctr-pages.act-new").length == 0) { return }

  const textarea = document.getElementById("page_content")

  textarea.addEventListener("dragover", function (event) {
    event.preventDefault()
  })

  textarea.addEventListener("drop", function (event) {
    event.preventDefault()

    // Get the dropped files
    const files = event.dataTransfer.files

    // Ensure that files were dropped
    if (files.length > 0) {
      // Read the contents of the first file
      const file = files[0]
      const reader = new FileReader()

      reader.onload = function (e) {
        // Set the textarea value to the file contents
        textarea.value = e.target.result
      }

      // Read the file as text
      reader.readAsText(file)
    }
  })
})
