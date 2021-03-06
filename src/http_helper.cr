require "cossack"

# Method for redirections using the cossack http client
module DPPM::HTTPHelper
  extend self

  def get_string(url)
    response = Cossack::Client.new(&.use Cossack::RedirectionMiddleware).get url
    case response.status
    when 200, 301, 302 then response.body
    else
      raise "Status code #{response.status}: " + url
    end
  rescue ex
    raise Error.new "Failed to get #{url.colorize.underline}", ex
  end

  def get_file(url : String, path : String = File.basename(url))
    File.write path, self.get_string(url)
  end

  def url?(link) : Bool
    link.starts_with?("http://") || link.starts_with?("https://")
  end
end
