class RenameJobApplicationLogoDataToLogo < ActiveRecord::Migration[7.1]
  # `logo_data` was named for the only thing it could hold — a cropped image as
  # a data URL. It now takes anything an icon reference can be, the same set a
  # chore's `icon` holds: an emoji, a Tabler class, a `hicon:` pointing at one
  # of the household's own uploads, inline SVG, or still an image. The column
  # is no longer about the DATA, so it stops saying so.
  def change
    rename_column :job_applications, :logo_data, :logo
  end
end
