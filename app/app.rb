require 'app/libraries'

module Hurl
  class App < Sinatra::Base
    register Mustache::Sinatra
    helpers Hurl::Helpers

    dir = File.dirname(File.expand_path(__FILE__))

    set :public_folder,   "#{dir}/../public"
    set :root,            RACK_ROOT
    set :app_file,        __FILE__
    set :static,          true

    set :protection, :except => :frame_options

    set :views, "#{dir}/templates"

    set :mustache, {
      :namespace => Object,
      :views     => "#{dir}/views",
      :templates => "#{dir}/templates"
    }

    enable :sessions

    def initialize(*args)
      super
      @debug    = ENV['DEBUG']
      @ga_code  = ENV['GA_CODE']
      @website  = ENV['WEBSITE']
      setup_default_hurls
    end

    #
    # routes
    #

    before do
      @flash = session.delete('flash')
    end

    get '/' do
      @hurl = params
      mustache :index
    end

    get '/hurls/:id/?' do
      @hurl = find_hurl_or_view(params[:id])
      @hurl ? mustache(:index) : not_found
    end

    get '/hurls/:id/:view_id/?' do
      @hurl = find_hurl_or_view(params[:id])
      @view = find_hurl_or_view(params[:view_id])
      @view_id = params[:view_id]
      @hurl && @view ? mustache(:index) : not_found
    end

    get '/views/:id/?' do
      @view = find_hurl_or_view(params[:id])
      @view ? mustache(:view, :layout => false) : not_found
    end

    get '/about/?' do
      mustache :about
    end

    get '/stats/?' do
      mustache :stats
    end

    post '/' do
      return json(:error => "Calm down and try my margarita!") if rate_limited?

      url, method, auth = params.values_at(:url, :method, :auth)

      return json(:error => "That's... wait.. what?!") if invalid_url?(url)

      curl = Curl::Easy.new(url)

      sent_headers = []
      curl.on_debug do |type, data|
        # track request headers
        sent_headers << data if type == Curl::CURLINFO_HEADER_OUT
      end

      curl.follow_location = true if params[:follow_redirects]

      # ensure a method is set
      method = (method.to_s.empty? ? 'GET' : method).upcase

      # update auth
      add_auth(auth, curl, params)

      # arbitrary headers
      add_headers_from_arrays(curl, params["header-keys"], params["header-vals"])

      # arbitrary post params
      if params['post-body'] && ['POST', 'PUT', 'PATCH'].index(method)
        post_data = [params['post-body']]
      else
        post_data = make_fields(method, params["param-keys"], params["param-vals"])
      end

      begin
        debug { puts "#{method} #{url}" }

        if post_data
          curl.post_body = stringify_data(post_data)
        end

        curl.http(method.upcase)

        debug do
          puts sent_headers.join("\n")
          puts post_data.join('&') if post_data.any?
          puts curl.header_str
        end

        header  = pretty_print_headers(curl.header_str)
        type    = url =~ /(\.js)$/ ? 'js' : curl.content_type
        body    = pretty_print(type, curl.body_str)
        request = pretty_print_requests(sent_headers, post_data)

        json :header    => header,
             :body      => body,
             :request   => request,
             :hurl_id   => save_hurl(params),
             :view_id   => save_view(header, body, request)
      rescue => e
        json :error => CGI::escapeHTML(e.to_s)
      end
    end

    #
    # error handlers
    #

    not_found do
      mustache :"404"
    end

    error do
      mustache :"500"
    end

    #
    # route helpers
    #

    # is this a url hurl can handle. basically a spam check.
    def invalid_url?(url)
      valid_schemes = ['http', 'https']
      begin
        uri = URI.parse(url)
        raise URI::InvalidURIError if uri.host == (ENV['WEBSITE'] || "hurl.it")
        raise URI::InvalidURIError if !valid_schemes.include? uri.scheme
        false
      rescue URI::InvalidURIError
        true
      end
    end

    # update auth based on auth type
    def add_auth(auth, curl, params)
      if auth == 'basic'
        username, password = params.values_at(:username, :password)
        encoded = Base64.encode64("#{username}:#{password}").gsub("\n",'')
        curl.headers['Authorization'] = "Basic #{encoded}"
      end
    end

    # headers from non-empty keys and values
    def add_headers_from_arrays(curl, keys, values)
      keys, values = Array(keys), Array(values)

      keys.each_with_index do |key, i|
        next if values[i].to_s.empty?
        curl.headers[key] = values[i]
      end
    end

    # post params from non-empty keys and values
    def make_fields(method, keys, values)
      return [] unless %w( POST PUT PATCH ).include? method

      fields = []
      keys, values = Array(keys), Array(values)
      keys.each_with_index do |name, i|
        value = values[i]
        next if name.to_s.empty? || value.to_s.empty?
        fields << Curl::PostField.content(name, value)
      end
      fields
    end

    def save_view(header, body, request)
      hash = { 'header' => header, 'body' => body, 'request' => request }
      id = sha(hash.to_s)
      DB.save(:views, id, hash)
      id
    end

    def save_hurl(params)
      id = sha(params.to_s)
      DB.save(:hurls, id, params.merge(:id => id))
      id
    end

    def find_hurl_or_view(id)
      DB.find(:hurls, id) || DB.find(:views, id)
    end

    # has this person made too many requests?
    def rate_limited?
      false
    end

    # turn post_data into a string for PUT requests
    def stringify_data(data)
      if data.is_a? String
        data
      elsif data.is_a? Array
        data.map { |x| stringify_data(x) }.join("&")
      elsif data.is_a? Curl::PostField
        data.to_s
      else
        raise "Cannot stringify #{data.inspect}"
      end
    end
  end
end
