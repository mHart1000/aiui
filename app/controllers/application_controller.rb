class ApplicationController < ActionController::API
  include ActionController::MimeResponds

  attr_reader :current_user

  private

  def authenticate_with_jwt!
    auth_header = request.headers['Authorization'].to_s

    if auth_header.blank?
      return render json: { error: 'Missing Authorization header' }, status: :unauthorized
    end

    token = auth_header.split(' ').last

    begin
      payload, = JWT.decode(
        token,
        ENV['DEVISE_JWT_SECRET_KEY'],
        true,
        algorithm: 'HS256'
      )

      @current_user = User.find(payload['sub'])
    rescue JWT::DecodeError
      render json: { error: 'Invalid or expired token' }, status: :unauthorized
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'User not found' }, status: :unauthorized
    end
  end
end
