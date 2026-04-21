module Api
  class RagDocumentsController < ApplicationController
    before_action :authenticate_api_user!

    ACCEPTED_FORMATS = {
      "pdf"  => "pdf",
      "txt"  => "txt",
      "md"   => "md",
      "markdown" => "md",
      "docx" => "docx",
      "json" => "json"
    }.freeze

    UPLOAD_DIR = Rails.root.join("tmp", "rag_uploads").freeze

    def index
      docs = current_api_user.rag_documents.order(created_at: :desc)
      render json: docs.map { |d| serialize(d) }
    end

    def create
      file = params[:file]
      unless file.respond_to?(:original_filename) && file.respond_to?(:tempfile)
        return render json: { error: "missing file" }, status: :unprocessable_entity
      end

      ext = File.extname(file.original_filename).delete_prefix(".").downcase
      format = ACCEPTED_FORMATS[ext]
      unless format
        return render json: { error: "unsupported file format: #{ext}" }, status: :unprocessable_entity
      end

      doc = current_api_user.rag_documents.create!(
        source_type: "personalization",
        title: File.basename(file.original_filename, ".*"),
        original_filename: file.original_filename,
        file_format: format,
        status: "pending"
      )

      stable_path = persist_upload(file, doc)
      RagIngestionJob.perform_later(doc.id, stable_path.to_s)

      render json: serialize(doc), status: :created
    end

    def destroy
      doc = current_api_user.rag_documents.find(params[:id])
      doc.destroy!
      head :no_content
    end

    private

    def serialize(doc)
      {
        id: doc.id,
        title: doc.title,
        original_filename: doc.original_filename,
        file_format: doc.file_format,
        source_type: doc.source_type,
        status: doc.status,
        error_message: doc.error_message,
        chunk_count: doc.rag_chunks.count,
        created_at: doc.created_at
      }
    end

    def persist_upload(file, doc)
      FileUtils.mkdir_p(UPLOAD_DIR)
      safe_name = file.original_filename.gsub(/[^\w.\-]+/, "_")
      dest = UPLOAD_DIR.join("#{doc.id}-#{safe_name}")
      FileUtils.cp(file.tempfile.path, dest)
      dest
    end
  end
end
