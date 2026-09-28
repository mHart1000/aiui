module Api
  class ConversationsController < ApplicationController
    before_action :authenticate_api_user!
    respond_to :json

    def index
      conversations = current_api_user.conversations.includes(:user).order(updated_at: :desc)
      render json: conversations.map { |c|
        {
          id: c.id,
          title: c.title,
          model_code: c.model_code,
          rag_enabled: c.rag_enabled,
          web_search_mode: c.resolved_web_search_mode,
          web_search_level: c.resolved_web_search_level,
          updated_at: c.updated_at
        }
      }
    end

    def search
      q = params[:q].to_s.strip
      return render json: [] if q.blank?

      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(q)}%"
      scope = current_api_user.conversations

      title_ids = scope.where("title ILIKE ?", pattern).pluck(:id)
      content_ids = scope.joins(:messages).where("messages.content ILIKE ?", pattern).distinct.pluck(:id)

      snippets = {}
      Message.where(conversation_id: content_ids)
             .where("content ILIKE ?", pattern)
             .order(:created_at)
             .each { |m| snippets[m.conversation_id] ||= snippet_for(m.content, q) }

      conversations = scope.where(id: (title_ids + content_ids).uniq).includes(:user).order(updated_at: :desc)
      render json: conversations.map { |c|
        {
          id: c.id,
          title: c.title,
          model_code: c.model_code,
          rag_enabled: c.rag_enabled,
          web_search_mode: c.resolved_web_search_mode,
          web_search_level: c.resolved_web_search_level,
          updated_at: c.updated_at,
          snippet: snippets[c.id]
        }
      }
    end

    def show
      conversation = current_api_user.conversations.includes(:messages).find(params[:id])

      render json: {
        id: conversation.id,
        title: conversation.title,
        model_code: conversation.model_code,
        rag_enabled: conversation.rag_enabled,
        web_search_mode: conversation.resolved_web_search_mode,
        web_search_level: conversation.resolved_web_search_level,
        use_skills: conversation.resolved_use_skills,
        skill_ids: conversation.resolved_skills.map(&:id),
        messages: conversation.messages.order(:created_at).includes(images_attachments: :blob).map { |m|
          {
            id: m.id,
            role: m.role,
            content: m.content,
            thinking: m.thinking,
            total_tokens: m.total_tokens,
            tokens_per_second: m.tokens_per_second,
            generation_ms: m.generation_ms,
            web_search_data: m.web_search_data,
            images: m.images.attachments.map { |a|
              {
                id: a.id,
                filename: a.blob.filename.to_s,
                url: rails_storage_proxy_path(a.blob, disposition: "inline", only_path: true)
              }
            }
          }
        }
      }
    end

    def create
      conversation = current_api_user.conversations.create!(title: "New Chat")
      render json: { id: conversation.id }
    end

    def create_fork
      conversation = current_api_user.conversations.find(params[:id])
      message = conversation.messages.find(params[:message_id])
      forked = conversation.fork_at(message)
      render json: { id: forked.id }, status: :created
    end

    def duplicate
      conversation = current_api_user.conversations.find(params[:id])
      message = conversation.messages.order(:created_at, :id).last
      return render json: { error: "Conversation has no messages" }, status: :unprocessable_entity unless message

      duplicated = conversation.fork_at(message)
      render json: { id: duplicated.id }, status: :created
    end

    def update
      conversation = current_api_user.conversations.find(params[:id])
      conversation.update!(conversation_params)
      render_conversation_settings(conversation)
    end

    def web_search_settings
      conversation = current_api_user.conversations.find(params[:id])
      attrs = web_search_settings_params

      ActiveRecord::Base.transaction do
        current_api_user.update!(attrs)
        conversation.update!(attrs)
      end

      render_conversation_settings(conversation)
    rescue ActiveRecord::RecordInvalid => e
      render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
    end

    private

    def render_conversation_settings(conversation)
      render json: {
        id: conversation.id,
        title: conversation.title,
        model_code: conversation.model_code,
        rag_enabled: conversation.rag_enabled,
        web_search_mode: conversation.resolved_web_search_mode,
        web_search_level: conversation.resolved_web_search_level,
        use_skills: conversation.resolved_use_skills,
        skill_ids: conversation.resolved_skills.map(&:id)
      }
    end

    def destroy
      current_api_user.conversations.find(params[:id]).destroy!
      head :no_content
    end

    private

    # Splits `content` around the first match of `query` into windowed
    # before/match/after parts so the client can highlight and center the match.
    def snippet_for(content, query, window: 80)
      flat = content.to_s.gsub(/\s+/, " ").strip
      idx = flat.downcase.index(query.downcase)
      return nil if idx.nil?

      match = flat[idx, query.length]
      before = flat[0...idx]
      after = flat[(idx + query.length)..] || ""

      before = "…#{before[-window..]}" if before.length > window
      after = "#{after[0, window]}…" if after.length > window

      { before: before, match: match, after: after }
    end

    def conversation_params
      params.require(:conversation).permit(:rag_enabled, :web_search_mode, :web_search_level, :use_skills, skill_ids: [])
    end

    def web_search_settings_params
      params.require(:web_search).permit(:web_search_mode, :web_search_level)
    end
  end
end
