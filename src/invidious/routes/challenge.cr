require "http/cookie"

module Invidious::Routes::Challenge
  def self.page(env)
    if env.request.cookies.has_key? "pow-vc" || verify_visit_cookie(env.request.cookies["pow-vc"].value)
      if env.params.query.has_key? "redirect"
        env.redirect env.params.query["redirect"]
      else
        env.redirect "/"
      end
    end

    challenge = PoWChallenge.new.to_str
    navbar_search = false

    templated "pow_challenge"
  end

  def self.verify(env)
    if !env.params.body["answer"]
      env.response.status_code = 403
    elsif !PoWAnswer.from_str(env.params.body["answer"]).verify
      env.response.status_code = 403
    end

    env.response.cookies["pow-vc"] = HTTP::Cookie.new name: "pow-vc", value: generate_visit_cookie(), path: "/", expires: Time.utc + Time::Span.new(days: 5 * 365)
    env.response.status_code = 200
  end
end
