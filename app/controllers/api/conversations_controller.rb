module Api
  class ConversationsController < ApplicationController
    before_action :authenticate_api_user!
    respond_to :json

    def index
      conversations = current_api_user.conversations.order(updated_at: :desc)
      render json: conversations.map { |c|
        {
          id: c.id,
          title: c.title,
          model_code: c.model_code,
          rag_enabled: c.rag_enabled,
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

      conversations = scope.where(id: (title_ids + content_ids).uniq).order(updated_at: :desc)
      render json: conversations.map { |c|
        {
          id: c.id,
          title: c.title,
          model_code: c.model_code,
          rag_enabled: c.rag_enabled,
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
        messages: conversation.messages.order(:created_at).map { |m|
          {
            id: m.id,
            role: m.role,
            content: m.content,
            thinking: m.thinking,
            total_tokens: m.total_tokens,
            tokens_per_second: m.tokens_per_second,
            generation_ms: m.generation_ms
          }
        }
      }
    end

    def create
      conversation = current_api_user.conversations.create!(title: "New Chat")
      render json: { id: conversation.id }
    end

    def update
      conversation = current_api_user.conversations.find(params[:id])
      conversation.update!(conversation_params)
      render json: {
        id: conversation.id,
        title: conversation.title,
        model_code: conversation.model_code,
        rag_enabled: conversation.rag_enabled
      }
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
      params.require(:conversation).permit(:rag_enabled)
    end
  end
end
