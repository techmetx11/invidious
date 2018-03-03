# "Invidious" (which indexes popular video sites)
# Copyright (C) 2018  Omar Roth
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

require "kemal"
require "option_parser"
require "pg"
require "xml"
require "./helpers"

threads = 10
sleep_time = 1.0
Kemal.config.extra_options do |parser|
  parser.banner = "Usage: invidious [arguments]"
  parser.on("-t THREADS", "--threads=THREADS", "Number of threads for crawling (default: 10)") do |number|
    begin
      threads = number.to_i32
    rescue ex
      puts "THREADS must be integer"
      exit
    end
  end
  parser.on("-w TIME", "--wait=TIME", "Time to wait between server requests in seconds (default: 1 second)") do |number|
    begin
      sleep_time = number.to_f64
    rescue ex
      puts "TIME must be integer or float"
      exit
    end
  end
end

Kemal::CLI.new

PG_DB   = DB.open "postgres://kemal:kemal@localhost:5432/invidious"
YT_URL  = URI.parse("https://www.youtube.com")
CONTEXT = OpenSSL::SSL::Context::Client.new
CONTEXT.verify_mode = OpenSSL::SSL::VerifyMode::NONE
CONTEXT.add_options(
  OpenSSL::SSL::Options::ALL |
  OpenSSL::SSL::Options::NO_SSL_V2 |
  OpenSSL::SSL::Options::NO_SSL_V3
)
youtube_pool = Deque.new((threads * 1.2 + 1).to_i) do
  make_client(YT_URL, CONTEXT)
end
reddit_pool = Deque.new((threads * 1.2 + 1).to_i) do
  make_client(URI.parse("https://api.reddit.com"), CONTEXT)
end

# Refresh youtube_pool by crawling YT
threads.times do
  spawn do
    io = STDOUT
    ids = Deque(String).new
    random = Random.new
    yt_client = get_client(youtube_pool)

    search(random.base64(3), yt_client) do |id|
      ids << id
    end

    youtube_pool << yt_client

    loop do
      yt_client = get_client(youtube_pool)

      if ids.empty?
        search(random.base64(3), yt_client) do |id|
          ids << id
        end
      end

      if rand(300) < 1
        youtube_pool << make_client(YT_URL, CONTEXT)
        yt_client = get_client(youtube_pool)
      end

      begin
        id = ids[0]
        video = get_video(id, yt_client, PG_DB)
      rescue ex
        io << id << " : " << ex.message << "\n"
        youtube_pool << make_client(YT_URL, CONTEXT)
        next
      ensure
        ids.delete(id)
      end

      rvs = [] of Hash(String, String)
      if video.info.has_key?("rvs")
        video.info["rvs"].split(",").each do |rv|
          rvs << HTTP::Params.parse(rv).to_h
        end
      end

      rvs.each do |rv|
        if rv.has_key?("id") && !PG_DB.query_one?("SELECT EXISTS (SELECT true FROM videos WHERE id = $1)", rv["id"], as: Bool)
          ids.delete(id)
          ids << rv["id"]
          if ids.size == 150
            ids.shift
          end
        end
      end

      sleep sleep_time.seconds

      youtube_pool << yt_client
    end
  end
end

threads.times do
  spawn do
    loop do
      client = get_client(reddit_pool)

      begin
        client.get("/")
      rescue ex
        STDOUT << "Reddit client : " << ex.message << "\n"
        reddit_pool << make_client(URI.parse("https://api.reddit.com"), CONTEXT)
        next
      end

      sleep sleep_time.seconds

      reddit_pool << client
    end
  end
end

top_videos = [] of Video

spawn do
  loop do
    top = rank_videos(PG_DB, 40)
    client = get_client(youtube_pool)

    args = [] of String
    if top.size > 0
      (1..top.size).each { |i| args << "($#{i})," }
      args = args.join("")
      args = args.chomp(",")
    else
      next
    end

    videos = [] of Video

    PG_DB.query("SELECT * FROM videos d INNER JOIN (VALUES #{args}) v(id) USING (id)", top) do |rs|
      rs.each do
        video = rs.read(Video)
        videos << video
      end
    end

    top_videos = videos

    youtube_pool << client
  end
end

macro templated(filename)
    render "src/views/#{{{filename}}}.ecr", "src/views/layout.ecr"
  end

get "/" do |env|
  templated "index"
end

get "/watch" do |env|
  if env.params.query["v"]?
    id = env.params.query["v"]
  else
    env.redirect "/"
    next
  end

  listen = false
  if env.params.query["listen"]? && env.params.query["listen"] == "true"
    listen = true
    env.params.query.delete_all("listen")
  end

  yt_client = get_client(youtube_pool)
  begin
    video = get_video(id, yt_client, PG_DB)
  rescue ex
    error_message = ex.message
    next templated "error"
  ensure
    youtube_pool << yt_client
  end

  fmt_stream = [] of HTTP::Params
  video.info["url_encoded_fmt_stream_map"].split(",") do |string|
    fmt_stream << HTTP::Params.parse(string)
  end

  signature = false
  if fmt_stream[0]? && fmt_stream[0]["s"]?
    signature = true
  end

  # We want lowest quality first
  fmt_stream.reverse!

  adaptive_fmts = [] of HTTP::Params
  if video.info.has_key?("adaptive_fmts")
    video.info["adaptive_fmts"].split(",") do |string|
      adaptive_fmts << HTTP::Params.parse(string)
    end
  end

  if signature
    adaptive_fmts.each do |fmt|
      fmt["url"] += "&signature=" + decrypt_signature(fmt["s"])
    end

    fmt_stream.each do |fmt|
      fmt["url"] += "&signature=" + decrypt_signature(fmt["s"])
    end
  end

  rvs = [] of Hash(String, String)
  if video.info.has_key?("rvs")
    video.info["rvs"].split(",").each do |rv|
      rvs << HTTP::Params.parse(rv).to_h
    end
  end

  player_response = JSON.parse(video.info["player_response"])

  rating = video.info["avg_rating"].to_f64

  engagement = ((video.dislikes.to_f + video.likes.to_f)/video.views * 100)

  if video.likes > 0 || video.dislikes > 0
    calculated_rating = (video.likes.to_f/(video.likes.to_f + video.dislikes.to_f) * 4 + 1)
  else
    calculated_rating = 0.0
  end

  reddit_client = get_client(reddit_pool)
  begin
    reddit_comments, reddit_thread = get_reddit_comments(id, reddit_client)
  rescue ex
    reddit_comments = JSON.parse("[]")
    reddit_thread = nil
  ensure
    reddit_pool << reddit_client
  end

  templated "watch"
end

get "/search" do |env|
  if env.params.query["q"]?
    query = env.params.query["q"]
  else
    env.redirect "/"
    next
  end

  page = env.params.query["page"]? && env.params.query["page"].to_i? ? env.params.query["page"].to_i : 1

  client = get_client(youtube_pool)

  html = client.get("https://www.youtube.com/results?q=#{URI.escape(query)}&page=#{page}&sp=EgIQAVAU").body
  html = XML.parse_html(html)

  videos = Array(Hash(String, String)).new

  html.xpath_nodes(%q(//ol[@class="item-section"]/li)).each do |item|
    root = item.xpath_node(%q(div[contains(@class,"yt-lockup-video")]/div))
    if root
      video = {} of String => String

      link = root.xpath_node(%q(div[contains(@class,"yt-lockup-thumbnail")]/a/@href))
      if link
        video["link"] = link.content
      else
        video["link"] = "#"
      end

      title = root.xpath_node(%q(div[@class="yt-lockup-content"]/h3/a))
      if title
        video["title"] = title.content
      else
        video["title"] = "Something went wrong"
      end

      thumbnail = root.xpath_node(%q(div[contains(@class,"yt-lockup-thumbnail")]/a/div/span/img/@src))
      if thumbnail && !thumbnail.content.ends_with?(".gif")
        video["thumbnail"] = thumbnail.content
      else
        thumbnail = root.xpath_node(%q(div[contains(@class,"yt-lockup-thumbnail")]/a/div/span/img/@data-thumb))
        if thumbnail
          video["thumbnail"] = thumbnail.content
        else
          video["thumbnail"] = "http://via.placeholder.com/246x138"
        end
      end

      author = root.xpath_node(%q(div[@class="yt-lockup-content"]/div/a))
      if author
        video["author"] = author.content
        video["author_url"] = author["href"]
      else
        video["author"] = ""
        video["author_url"] = ""
      end

      videos << video
    end
  end

  youtube_pool << client

  templated "search"
end

error 404 do |env|
  error_message = "404 Page not found"
  templated "error"
end

error 500 do |env|
  error_message = "500 Server error"
  templated "error"
end

public_folder "assets"

Kemal.run
