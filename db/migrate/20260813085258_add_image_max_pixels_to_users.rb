class AddImageMaxPixelsToUsers < ActiveRecord::Migration[8.1]
  # Images above this pixel count are downscaled to it on upload.
  # Re-derive when the model or llama.cpp context changes — docs/image-attachments-spec.md §2.2.
  def change
    add_column :users, :image_max_pixels, :integer, default: 6_000_000
  end
end
