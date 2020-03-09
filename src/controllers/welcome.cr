require "./application"

module PlaceOS::Drivers::Api
  class Welcome < Application
    base "/"

    STATIC_FILE_PATH = File.join(File.expand_path(ENV["PUBLIC_WWW_PATH"]? || "./www"), "index.html")

    def index
      file_path = STATIC_FILE_PATH
      response.content_type = MIME.from_filename(file_path, "application/octet-stream")
      response.content_length = File.size(file_path)
      File.open(file_path) do |file|
        IO.copy(file, response)
      end
    end
  end
end
