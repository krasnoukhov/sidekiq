require 'sidekiq'
require 'sidekiq/actor'

module Sidekiq
  ##
  # The Fetcher blocks on Redis, waiting for a message to process
  # from the queues.  It gets the message and hands it to the Manager
  # to assign to a ready Processor.
  class Fetcher
    include Util
    include Actor

    TIMEOUT = 1

    def initialize(mgr, options)
      @down = nil
      @mgr = mgr
      @strategy = Fetcher.strategy.new(options)
    end

    # Fetching is straightforward: the Manager makes a fetch
    # request for each idle processor when Sidekiq starts and
    # then issues a new fetch request every time a Processor
    # finishes a message.
    #
    # Because we have to shut down cleanly, we can't block
    # forever and we can't loop forever.  Instead we reschedule
    # a new fetch if the current fetch turned up nothing.
    def fetch
      watchdog('Fetcher#fetch died') do
        return if Sidekiq::Fetcher.done?

        begin
          work = @strategy.retrieve_work
          ::Sidekiq.logger.info("Redis is online, #{Time.now.to_f - @down.to_f} sec downtime") if @down
          @down = nil

          if work
            @mgr.async.assign(work)
          else
            # Patch: Next fetch after timeout (prevent 100% cpu load)
            if @strategy.is_a?(ScheduleFetch)
              after(TIMEOUT) { fetch }
            else
              after(0) { fetch }
            end
          end
        rescue => ex
          handle_exception(ex)
        end

      end
    end

    def handle_exception(ex)
      if !@down
        logger.error("Error fetching message: #{ex}")
        ex.backtrace.each do |bt|
          logger.error(bt)
        end
      end
      @down ||= Time.now
      sleep(TIMEOUT)
      after(0) { fetch }
    rescue Task::TerminatedError
      # If redis is down when we try to shut down, all the fetch backlog
      # raises these errors.  Haven't been able to figure out what I'm doing wrong.
    end

    # Ugh.  Say hello to a bloody hack.
    # Can't find a clean way to get the fetcher to just stop processing
    # its mailbox when shutdown starts.
    def self.done!
      @done = true
    end

    def self.done?
      @done
    end

    def self.strategy
      if ENV['SCHEDULE']
        ScheduleFetch
      else
        Sidekiq.options[:fetch] || BasicFetch
      end
    end
  end

  class BasicFetch
    def initialize(options)
      @strictly_ordered_queues = !!options[:strict]
      @queues = options[:queues].map { |q| "queue:#{q}" }
      @unique_queues = @queues.uniq
    end

    def retrieve_work
      work = Sidekiq.redis { |conn| conn.brpop(*queues_cmd) }
      UnitOfWork.new(*work) if work
    end

    def self.bulk_requeue(inprogress)
      Sidekiq.logger.debug { "Re-queueing terminated jobs" }
      jobs_to_requeue = {}
      inprogress.each do |unit_of_work|
        jobs_to_requeue[unit_of_work.queue_name] ||= []
        jobs_to_requeue[unit_of_work.queue_name] << unit_of_work.message
      end

      Sidekiq.redis do |conn|
        jobs_to_requeue.each do |queue, jobs|
          conn.rpush("queue:#{queue}", jobs)
        end
      end
      Sidekiq.logger.info("Pushed #{inprogress.size} messages back to Redis")
    rescue => ex
      Sidekiq.logger.warn("Failed to requeue #{inprogress.size} jobs: #{ex.message}")
    end

    UnitOfWork = Struct.new(:queue, :message) do
      def acknowledge
        # nothing to do
      end

      def queue_name
        queue.gsub(/.*queue:/, '')
      end

      def requeue
        Sidekiq.redis do |conn|
          conn.rpush("queue:#{queue_name}", message)
        end
      end
    end

    # Creating the Redis#blpop command takes into account any
    # configured queue weights. By default Redis#blpop returns
    # data from the first queue that has pending elements. We
    # recreate the queue command each time we invoke Redis#blpop
    # to honor weights and avoid queue starvation.
    def queues_cmd
      queues = @strictly_ordered_queues ? @unique_queues.dup : @queues.shuffle.uniq
      queues << Sidekiq::Fetcher::TIMEOUT
    end
  end

  # PATCH: Scheduled fetcher strategy
  class ScheduleFetch
    ZPOP = <<-LUA
      local val = redis.call('zrangebyscore', KEYS[1], '-inf', KEYS[2], 'LIMIT', 0, 1)
      if val then redis.call('zrem', KEYS[1], val[1]) end
      return val[1]
    LUA
    
    def initialize(options)
      @queues = %w(schedule)
    end

    def retrieve_work
      work = Sidekiq.redis { |conn|
        sorted_set = @queues.sample
        namespace = conn.namespace
        now = Time.now.to_f.to_s
        
        message = conn.eval(ZPOP, ["#{namespace}:#{sorted_set}", now], {})
        if message
          msg = Sidekiq.load_json(message)
          
          # Keep message in schedule
          if sorted_set == 'schedule'
            conn.zadd('schedule', (Time.new + msg['expiration']).to_f.to_s, message)
          end
          
          ["queue:#{msg['queue']}", message]
        end
      }
      UnitOfWork.new(*work) if work
    end

    def self.bulk_requeue(inprogress)
      Sidekiq.logger.debug { "Re-queueing terminated jobs" }
      jobs_to_requeue = {}
      inprogress.each do |unit_of_work|
        jobs_to_requeue[unit_of_work.queue_name] ||= []
        jobs_to_requeue[unit_of_work.queue_name] << unit_of_work.message
      end

      Sidekiq.redis do |conn|
        jobs_to_requeue.each do |queue, jobs|
          conn.rpush("queue:#{queue}", jobs)
        end
      end
      Sidekiq.logger.info("Pushed #{inprogress.size} messages back to Redis")
    rescue => ex
      Sidekiq.logger.warn("Failed to requeue #{inprogress.size} jobs: #{ex.message}")
    end

    UnitOfWork = Struct.new(:queue, :message) do
      def acknowledge
        # nothing to do
      end

      def queue_name
        queue.gsub(/.*queue:/, '')
      end

      def requeue
        Sidekiq.redis do |conn|
          conn.zadd("schedule", (Time.now.to_f + 60).to_s, message)
        end
      end
    end
  end
end
