class Conversation < ApplicationRecord
  PLACEHOLDER_TITLE = "New Chat".freeze

  # Message columns carried over by a fork. Explicit so new columns have to opt in.
  # Attached images are not columns; copy_attachments handles them.
  COPIED_MESSAGE_COLUMNS = %w[
    role content thinking prompt_tokens completion_tokens total_tokens
    generation_ms tokens_per_second persona_version skill_versions
    created_at updated_at
  ].freeze

  has_many :messages, dependent: :destroy
  belongs_to :user

  def entitle_async(content)
    return if title.present? && !placeholder_title?
    ConversationEntitleJob.perform_later(id, content)
  end

  def messages_for_ai(multimodal: false)
    messages.order(:created_at)
            .includes(images_attachments: :blob)
            .map { |m| m.to_ai_payload(multimodal: multimodal) }
  end

  # Copies this conversation and its messages up to and including `message`.
  def fork_at(message)
    ordered = messages.order(:created_at, :id).to_a
    # Cut by position, not by created_at, so identical timestamps stay unambiguous.
    cutoff = ordered.index { |m| m.id == message.id }
    return nil if cutoff.nil?

    transaction do
      forked = user.conversations.create!(
        title: fork_title,
        model_code: model_code,
        rag_enabled: rag_enabled,
        use_skills: use_skills,
        skill_ids: skill_ids
      )
      source_slice = ordered[0..cutoff]
      # insert_all! skips the touch callback, so the source keeps its sidebar position.
      Message.insert_all!(source_slice.map { |m|
        m.attributes.slice(*COPIED_MESSAGE_COLUMNS).merge("conversation_id" => forked.id)
      })
      copy_attachments(source_slice, forked)
      forked
    end
  end

  # Destroys message and everything after it; position-based like fork_at.
  def truncate_from_message(message)
    ordered = messages.order(:created_at, :id).to_a
    cutoff = ordered.index { |m| m.id == message.id }
    return if cutoff.nil?

    Message.where(id: ordered[cutoff..].map(&:id)).destroy_all
  end

  # null on either override column means "inherit from the user".
  def resolved_use_skills
    use_skills.nil? ? user.use_skills : use_skills
  end

  # An explicit [] means no skills here; null falls back to the user's defaults.
  def resolved_skills
    return Skill.none unless resolved_use_skills

    if skill_ids.nil?
      user.skills.where(enabled_by_default: true).order(:id)
    else
      user.skills.where(id: skill_ids).order(:id)
    end
  end

  def apply_model_code(requested_code)
    validated = requested_code if AI_MODELS.map { |m| m["id"] }.include?(requested_code)
    resolved = validated || model_code
    update!(model_code: resolved) if model_code != resolved
    resolved
  end

  def add_assistant_message(reply:, thinking:, tokens:, stats: nil, persona_version: nil, skill_versions: nil)
    if tokens&.dig(:planning) && tokens&.dig(:execution)
      total_prompt = tokens[:planning][:prompt_tokens] + tokens[:execution][:prompt_tokens]
      total_completion = tokens[:planning][:completion_tokens] + tokens[:execution][:completion_tokens]
      total_all = tokens[:total]
    else
      total_prompt = tokens&.dig(:prompt_tokens) || 0
      total_completion = tokens&.dig(:completion_tokens) || 0
      total_all = tokens&.dig(:total_tokens) || 0
    end

    messages.create!(
      role: "assistant",
      content: reply,
      thinking: thinking,
      prompt_tokens: total_prompt,
      completion_tokens: total_completion,
      total_tokens: total_all,
      generation_ms: stats&.dig(:elapsed_ms),
      tokens_per_second: stats&.dig(:tokens_per_second),
      persona_version: persona_version,
      skill_versions: skill_versions
    )
  end

  def placeholder_title?
    title == PLACEHOLDER_TITLE
  end

  def entitle(content)
    return if title.present? && !placeholder_title?

    begin
      result = ChatService.call(
        messages: [
          { role: "system", content: "Generate a short 3-6 word chat title in the style of an article title, based on the following user message. No punctuation." },
          { role: "user", content: content }
        ],
        model: model_code,
        use_persona: false,
        use_scaffolding: false,
        max_tokens: 20,
        log_stats: false
      )

      chosen_title = result[:reply].presence || content[0..40]
      update!(title: chosen_title.strip)
    rescue => e
      Rails.logger.warn("Failed to generate title: #{e.message}")
      update!(title: content[0..40])
    end
  end

  private

  # Blobs are copied rather than shared: a shared blob gets purged when either
  # conversation is destroyed, silently emptying the other one's images.
  def copy_attachments(source_messages, forked)
    return unless source_messages.any? { |m| m.images.attachments.any? }

    forked_messages = forked.messages.order(:created_at, :id).to_a
    source_messages.each_with_index do |source, i|
      source.images.attachments.each do |attachment|
        blob = attachment.blob
        forked_messages[i].images.attach(
          io: StringIO.new(blob.download),
          filename: blob.filename.to_s,
          content_type: blob.content_type
        )
      end
    end
  end

  def fork_title
    return PLACEHOLDER_TITLE if title.blank? || placeholder_title?
    "(fork) #{title.sub(/\A\(fork\) /, '')}"
  end
end
