require_relative 'user'
require_relative 'message'
require_relative 'channel'
require_relative 'session'
require_relative 'matchers/matcher_group'
require 'net/http'
require 'faye/websocket'
require 'eventmachine'
require 'json'

module SlackBot
  SLACK_AUTH_URL = 'https://slack.com/api/rtm.start?token='
  attr_accessor :socket
  attr_writer :debug
  attr_reader :team_info
  attr_reader :session
  attr_accessor :auth_url
  
  def initialize(auth_key, options={})
    @debug = options[:log]
    @key = auth_key.strip
    setup()
  end
  
  def setup
    @matchers = Hash.new
    @session = Session.new
    @auth_url = SLACK_AUTH_URL
  end
  
  def get_url
    data = Net::HTTP.get(URI(@auth_url + @key))
    json = JSON.parse(data)
    @team_info = json
    if json['ok']
      return json['url']
    else
      raise "ERROR: #{json.to_s}"
    end
  end
  
  def run
    url = get_url()
    EM.run do
      @socket = ws = Faye::WebSocket::Client.new(url)

      ws.on :open do |event|
        log(:open, event.to_s)
        hook(:opened)
      end

      ws.on :message do |event|
        log(:action, event.data)
        begin
          json = JSON.parse(event.data)
          type = json.delete('type')
          if type
            hook(type, Message.new(json, self))
          else
            hook(:unknown, json)
          end
        rescue JSON::ParserError => e
          log(:error, e.message)
        end
        
      end

      ws.on :close do |event|
        log(:close, "#{event.code} #{event.reason}")
        @socket = ws = nil
        hook(:closed)
        EM.stop
      end
    end
  end
  
  def post(channel, message)
    if channel.is_a? String
      chan = channel
    elsif channel.is_a? Channel
      chan = channel.id
    else
      raise "Not a valid channel: #{channel}"
    end
    data = {
      id: 1,
      type: 'message',
      channel: chan,
      text: message.to_s
    }
    @socket.send data.to_json
  end
  
  def reply_to(msg, text)
    post(msg['channel'], text)
  end
   
  def channels
    @channels ||= load_channels
  end
  
  def channel(id)
    channels[id]
  end
   
  def user_channels
    @user_channels ||= load_user_channels
  end
  
  def user_channel(user)
    if user.is_a? User
      id = user.id
    else
      id = user
    end
    user_channels[id]
  end
  
  def users
    @users ||= load_users
  end
  
  def user(id)
    users[id]
  end
  
  def me
    @team_info['self']
  end
  
  def [](key)
    @team_info[key]
  end
  
  def log(type, message)
    if debug?
      puts "#{type}: #{message}"
    end
  end
  
  def debug?
    @debug
  end

  private
  def hook(action, *args)
    if self.respond_to? "#{action}_matcher"
      unless @matchers.has_key? action
        matcher_group = MatcherGroup.new(action)
        self.send("#{action}_matcher", matcher_group)
        @matchers[action] = matcher_group
      end
      begin
        @matchers[action].respond_for(args.first)
      rescue Exception => e
        puts e.message
        puts e.backtrace.join "\n"
      end
    elsif self.respond_to? action
      begin
        send(action, *args)
      rescue Exception => e
        puts e.message
        puts e.backtrace.join "\n"
      end
    end
  end

  def load_channels
    channels = Hash.new
    @team_info['channels'].each do |chan|
      channels[chan['id']] = Channel.new chan, self
    end
    channels
  end
 
  def load_user_channels
    channels = Hash.new
    @team_info['ims'].each do |chan|
      channels[chan['user']] = Channel.new chan, self
    end
    channels
  end

  def load_users
    users = Hash.new
    (@team_info['users'] + @team_info['bots']).map do |info| 
      users[info['id']] = User.new info, self
    end
    users
  end
end
