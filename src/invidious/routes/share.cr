require "uri"

module Invidious::Routes::Share
  def self.generate_share_link(env)
    locale = env.get("preferences").as(Preferences).locale

    user = env.get? "user"
    referer = get_referer(env)

    if !CONFIG.share_tokens_enabled
      return env.redirect referer
    end

    time = env.params.query["time"]?.try &.to_i || 0
    type = env.params.query["type"]?.try &.to_s || "text"

    token = generate_share_token(env.params.url["id"], Time.utc + Time::Span.new(seconds: time))

    if type == "html"
      env.set "generated_share_token", URI.encode(token)
      templated "share_token"
    else
      env.response.content_type = "text/plain"
      return "https://#{CONFIG.domain}/watch?v=#{env.params.url["id"]}&stoken=#{URI.encode(token)}"
    end
  end
end
