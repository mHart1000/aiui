class RagIngestionJob < ApplicationJob
  queue_as :default

  def perform(rag_document_id, path)
    doc = RagDocument.find_by(id: rag_document_id)
    unless doc
      Rails.logger.warn("RagIngestionJob: document #{rag_document_id} not found")
      cleanup_file(path)
      return
    end

    doc.update!(status: "processing")

    text = Rag::TextExtractor.call(doc, path: path)
    chunk_texts = Rag::TextChunker.call(text)

    if chunk_texts.empty?
      doc.update!(status: "failed", error_message: "No extractable content")
      return
    end

    document_model_id = nil

    chunk_texts.each_with_index do |chunk_text, idx|
      next if chunk_text.strip.empty?
      result = EmbeddingService.embed(text: chunk_text)
      document_model_id ||= result[:model]
      doc.rag_chunks.create!(
        user_id: doc.user_id,
        source_type: doc.source_type,
        content: chunk_text,
        chunk_index: idx,
        embedding: result[:vector],
        embedding_model: result[:model]
      )
    end

    doc.update!(status: "ready", embedding_model: document_model_id)
  rescue => e
    Rails.logger.error("RagIngestionJob failed for document #{rag_document_id}: #{e.message}")
    Rails.logger.error(e.backtrace.first(10).join("\n"))
    doc&.update(status: "failed", error_message: e.message.to_s[0, 500])
    raise
  ensure
    cleanup_file(path)
  end

  private

  def cleanup_file(path)
    File.delete(path) if path && File.exist?(path)
  rescue => e
    Rails.logger.warn("RagIngestionJob cleanup failed: #{e.message}")
  end
end
