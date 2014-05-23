# encoding: utf-8
require 'data_mapper'
require 'slim'

module Assassins
  class Game
    def winner
      alive = Player.all(:is_verified => true, :is_alive => true)
      if (alive.count == 1)
        alive[0]
      else
        nil
      end
    end
  end

  class App < Sinatra::Base
    before do
      @game = Game.first
      if @game.nil?
        @game = Game.new
        @game.save
      end
    end

    set(:game_state) do |*vals|
      condition {(vals.include? game_state)}
    end

    set(:freeforall) do |*vals|
      condition {(vals.include? freeforall)}
    end

    helpers do
      def game_state
        if defined?(@game_state) && !@game_state.nil?
          @game_state
        else
          if !@game.start_time.nil? && Time.now >= @game.start_time
            if Player.count(:is_verified => true, :is_alive => true) == 1
              @game_state = :postgame
            else
              @game_state = :ingame
            end
          else
            @game_state = :pregame
          end
        end
      end

      def freeforall
        $stderr.puts @game
        @game.freeforall
      end
    end

    get '/leaderboard', :game_state => [:ingame, :postgame] do
      slim :leaderboard, :locals => { :percent => 100 * Assassins::Player.count(:is_verified => true, :is_alive => true, :has_paid => true) / Assassins::Player.count(:is_verified => true, :has_paid => true) }
    end
  end
end

# vim:set ts=2 sw=2 et:
