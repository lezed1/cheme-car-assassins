# encoding: utf-8
require 'data_mapper'
require 'slim'

module Assassins
  class Player
    def send_verification (url)
      vars = [{:name => "LINK",
               :content => url},
              {:name => "SECRET",
               :content => self.secret}]
      send_email_template("verify-email", vars)
    end

    def send_email (subject, message)
      Email.send([{:email => self.email, :name => self.name}], subject, message)
    end

    def send_email_template (template, vars)
      if !Assassins::App.settings.development?
        rendered = Assassins::App.settings.mailer.templates.render(template, vars)
        message = {:to => [{:email => self.email,
                            :name => self.name}],
                   :global_merge_vars => vars,
                   :from_email => "DoNotReply@donlon6.tk",
                   :from_name => "Donlon 6 Assassins",
                   :subject => "Activate your Donlon 6 Assassins account",
                   :html => rendered["html"]}
        result = Assassins::App.settings.mailer.messages.send message, template
        $stderr.puts result
      else
        message = {:template => template,
                   :vars => vars}
        $stderr.puts message
      end
    end

    def self.send_email_all (subject, message)
      to = []
      players = Player.all(:is_verified => true)
      players.each do |player|
        to << {:email => player.email, :name => player.name}
      end
      Email.send(to, subject, message)
    end
  end

  class App < Sinatra::Base
    before do
      @player = nil
      if session.has_key? :player_id
        @player = Player.get session[:player_id]
        if @player.nil? || !@player.active?
          session.delete :player_id
        end
      end
    end

    set(:logged_in) do |val|
      condition {(!@player.nil? && @player.active?) == val}
    end

    get '/login' do
      slim :login
    end

    post '/login' do
      player = Player.first(:netid => params.has_key?('netid') ?
                              params['netid'].downcase.strip : nil)
      if (player.nil?)
        return slim :login, :locals => {:errors =>
          ['Invalid NetID. Please try again.']}
      end

      if (!player.active?)
        if (!player.is_verified)
          return redirect to('/signup/resend_verification')
        else
          return slim :login, :locals => {:errors =>
            ['You have been tagged and your account made inactive. Thanks for playing!']}
        end
      end

      if (!(params.has_key?('secret') &&
            player.secret.casecmp(params['secret']) == 0))
        return slim :login, :locals => {:errors =>
          ['Incorrect secret words. Please try again.']}
      end

      session[:player_id] = player.id
      redirect to('/dashboard')
    end

    get '/logout' do
      session.delete :player_id
      redirect to('/')
    end

    get '/signup', :game_state => :pregame do
      slim :signup
    end

    post '/signup', :game_state => :pregame do
      if (params.has_key?('netid') && params['netid'].index('@'))
        return slim :signup, :locals => {:errors =>
          ['Please enter only your NetID, not your full email address.']};
      end

      player = Player.new(:name => params['name'],
                          :netid => params.has_key?('netid') ?
                            params['netid'].downcase.strip : nil)
      player.generate_secret! 2
      if (player.save)
        player.send_verification(url("/signup/verify?aid=#{player.netid}&nonce=#{player.verification_key}"))
        slim :signup_confirm, :locals => {:netid => params['netid']}
      else
        slim :signup, :locals => {:errors => player.errors.full_messages}
      end
    end

    get '/signup/resend_verification', :game_state => :pregame do
      slim :resend_verification
    end

    post '/signup/resend_verification', :game_state => :pregame do
      player = Player.first(:netid => params['netid'])
      if (player.nil?)
        return slim :resend_verification, :locals => {:errors =>
          ['Invalid NetID']}
      end

      if (player.is_verified)
        return slim :resend_verification, :locals => {:errors =>
          ['That account has already been verified. You can log in using the form above.']}
      end

      player.verification_key = SecureRandom.uuid
      player.save!
      player.send_verification(url("/signup/verify?aid=#{player.netid}&nonce=#{player.verification_key}"))
      slim :signup_confirm
    end

    get '/signup/verify', :game_state => :pregame do
      player = Player.first(:netid => params['aid'])

      if (player.nil? || player.is_verified)
        return redirect to('/')
      end

      if (params.has_key?('nonce') && params['nonce'] == player.verification_key)
        player.is_verified = true;
        player.save!;
        session[:player_id] = player.id
        redirect to('/dashboard')
      else
        redirect to('/')
      end
    end

    get '/dashboard', :logged_in => true do
      slim :dashboard
    end

    post '/dashboard/assassinate', :logged_in => true, :game_state => :ingame do
      target = @player.target
      if (@player.failed_kill_attempts > 5)
        slim :dashboard, :locals => {:errors =>
          ["You have entered too many incorrect secret words. Please contact us to unlock your account."]}
      elsif (params.has_key?('target_secret') &&
               target.secret.casecmp(params['target_secret']) == 0)
        target.is_alive = false
        target.tagged_by = @player
        target.save!
        @player.kills += 1
        @player.failed_kill_attempts = 0
        @player.last_activity = Time.now
        @player.set_target_notify(target.target)
        @player.save!
        target.send_email('You were tagged!',
                          "You have been tagged by #{@player.name}. Thanks for playing!")
        redirect to('/dashboard')
      else
        @player.failed_kill_attempts += 1
        @player.save!
        slim :dashboard, :locals => {:errors =>
          ["That isn't your target's secret. Please try again."]}
      end
    end

    get '/dashboard/freeforall', :logged_in => true, :freeforall => true do
      slim :freeforall
    end

    post '/dashboard/freeforall/assassinate', :logged_in => true, :game_state => :ingame, :freeforall => true do
      target = Player.first(:secret => params['target_secret'], :is_verified => true, :is_alive => true)
      if (@player.failed_kill_attempts > 5)
        slim :dashboard, :locals => {:errors =>
          ["You have entered too many incorrect secret words. Please contact us to unlock your account."]}
      elsif (params.has_key?('target_secret') && target)
        assassin = Player.first(:target_id => target.id)
        target.is_alive = false
        target.tagged_by = assassin
        target.save!
        @player.kills += 1
        @player.failed_kill_attempts = 0
        @player.last_activity = Time.now
        @player.save!
        assassin.set_target_notify(target.target)
        assassin.save!
        target.send_email('You were tagged!',
                          "You have been tagged by #{@player.name}. Thanks for playing!")
        redirect to('/dashboard/freeforall')
      else
        @player.failed_kill_attempts += 1
        @player.save!
        slim :freeforall, :locals => {:errors =>
          ["That isn't your target's secret. Please try again."]}
      end
    end

    get /^\/dashboard(\/.*)?$/, :logged_in => false do
      redirect to('/login')
    end
  end
end

# vim:set ts=2 sw=2 et:
