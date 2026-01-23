module Api
  class MessagesController < ApplicationController
    before_action :authenticate_api_user!

    def create
      conversation = Conversation.find(params[:conversation_id])
      safe_model_code = params[:model_code] if AI_MODELS.map { |m| m["id"] }.include?(params[:model_code])
      safe_model_code ||= conversation.model_code
      conversation.update!(model_code: safe_model_code) if conversation.model_code != safe_model_code
      conversation.entitle(params[:content]) if conversation.messages.empty?

      user_message = conversation.messages.create!(
        role: "user",
        content: params[:content]
      )

      messages = conversation.messages
       .order(:created_at)
       .map { |m| { role: m.role, content: m.content } }

      result = OpenaiChatService.call(
        messages: messages,
        model: safe_model_code,
        use_persona: true,
        use_scaffolding: true
      )

      if result[:error]
        conversation.messages.create!(role: "assistant", content: "Error: #{result[:error]}")
        render json: { error: result[:error] }, status: :bad_gateway
      else
        reply = result[:reply]
        thinking = result[:thinking]
        tokens = result[:tokens]

        # Aggregate token usage from both passes (or single pass)
        if tokens&.dig(:planning) && tokens&.dig(:execution)
          # Two-pass mode: sum both passes
          total_prompt = tokens[:planning][:prompt_tokens] + tokens[:execution][:prompt_tokens]
          total_completion = tokens[:planning][:completion_tokens] + tokens[:execution][:completion_tokens]
          total_all = tokens[:total]
        else
          # Single-pass mode: use direct values
          total_prompt = tokens&.dig(:prompt_tokens) || 0
          total_completion = tokens&.dig(:completion_tokens) || 0
          total_all = tokens&.dig(:total_tokens) || 0
        end

        assistant_message = conversation.messages.create!(
          role: "assistant",
          content: reply,
          thinking: thinking,
          prompt_tokens: total_prompt,
          completion_tokens: total_completion,
          total_tokens: total_all
        )

        render json: {
          reply: reply,
          thinking: thinking,
          tokens: tokens
        }
      end
    end
  end
end
