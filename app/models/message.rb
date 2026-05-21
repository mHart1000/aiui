class Message < ApplicationRecord
  belongs_to :conversation, touch: true
end
