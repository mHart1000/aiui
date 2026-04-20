class ConversationEntitleJob < ApplicationJob
  queue_as :default

  def perform(conversation_id, content)
    conversation = Conversation.find_by(id: conversation_id)
    unless conversation
      Rails.logger.warn("ConversationEntitleJob: conversation #{conversation_id} not found")
      return
    end

    if conversation.title.present? && !conversation.placeholder_title?
      Rails.logger.info("ConversationEntitleJob: conversation #{conversation_id} already titled, skipping")
      return
    end

    conversation.entitle(content)
  rescue => e
    Rails.logger.error("ConversationEntitleJob failed: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
  end
end
