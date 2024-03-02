require_relative 'base/saver'
require_relative 'base/storage'
require 'uri'
require 'addressable/uri'

module Tanakai
  class Base
    class InvalidUrlError < StandardError; end

    # don't deep merge config's headers hash option
    DMERGE_EXCLUDE = [:headers]

    LoggerFormatter = proc do |severity, datetime, progname, msg|
      current_thread_id = Thread.current.object_id
      thread_type = Thread.main == Thread.current ? 'M' : 'C'
      output = format("%s, [%s#%d] [%s: %s] %5s -- %s: %s\n"
               .freeze, severity[0..0], datetime, $$, thread_type, current_thread_id, severity, progname, msg)

      if Tanakai.configuration.colorize_logger != false && Tanakai.env == 'development'
        Rbcat.colorize(output, predefined: %i[jsonhash logger])
      else
        output
      end
    end

    include BaseHelper

    ###

    class << self
      attr_reader :run_info, :savers, :storage
    end

    def self.running?
      @run_info && @run_info[:status] == :running
    end

    def self.completed?
      @run_info && @run_info[:status] == :completed
    end

    def self.failed?
      @run_info && @run_info[:status] == :failed
    end

    def self.visits
      @run_info && @run_info[:visits]
    end

    def self.items
      @run_info && @run_info[:items]
    end

    def self.update(type, subtype)
      return unless @run_info

      @update_mutex.synchronize { @run_info[type][subtype] += 1 }
    end

    def self.add_event(scope, event)
      return unless @run_info

      @update_mutex.synchronize { @run_info[:events][scope][event] += 1 }
    end

    ###

    @engine = :mechanize
    @pipelines = []
    @config = {}

    class << self
      attr_reader :name
    end

    def self.engine
      @engine ||= superclass.engine
    end

    def self.pipelines
      @pipelines ||= superclass.pipelines
    end

    class << self
      attr_reader :start_urls
    end

    def self.config
      if superclass.equal?(::Object)
        @config
      else
        superclass.config.deep_merge_excl(@config || {}, DMERGE_EXCLUDE)
      end
    end

    ###

    def self.logger
      @logger ||= Tanakai.configuration.logger || begin
        log_level = (ENV['LOG_LEVEL'] || Tanakai.configuration.log_level || 'DEBUG').to_s.upcase
        log_level = "Logger::#{log_level}".constantize
        Logger.new(STDOUT, formatter: LoggerFormatter, level: log_level, progname: name)
      end
    end

    def self.crawl!(exception_on_fail: true, data: {})
      logger.error "Spider: already running: #{name}" and return false if running?

      @storage = Storage.new
      @savers = {}
      @update_mutex = Mutex.new

      @run_info = {
        spider_name: name, status: :running, error: nil, environment: Tanakai.env,
        start_time: Time.new, stop_time: nil, running_time: nil,
        visits: { requests: 0, responses: 0 }, items: { sent: 0, processed: 0 },
        events: { requests_errors: Hash.new(0), drop_items_errors: Hash.new(0), custom: Hash.new(0) }
      }

      ###

      logger.info "Spider: started: #{name}"
      open_spider if respond_to? :open_spider

      spider = new
      spider.with_info = true
      if start_urls
        start_urls.each do |start_url|
          if start_url.instance_of?(Hash)
            spider.request_to(:parse, url: start_url[:url], data: data)
          else
            spider.request_to(:parse, url: start_url, data: data)
          end
        end
      else
        spider.parse(data: data)
      end
    rescue StandardError, SignalException, SystemExit => e
      @run_info.merge!(status: :failed, error: e.inspect)
      exception_on_fail ? raise(e) : [@run_info, e]
    else
      @run_info.merge!(status: :completed)
    ensure
      if spider
        spider.browser.destroy_driver! if spider.instance_variable_get('@browser')

        stop_time  = Time.now
        total_time = (stop_time - @run_info[:start_time]).round(3)
        @run_info.merge!(stop_time: stop_time, running_time: total_time)

        close_spider if respond_to? :close_spider

        message = "Spider: stopped: #{@run_info.merge(running_time: @run_info[:running_time]&.duration)}"
        failed? ? logger.fatal(message) : logger.info(message)

        @run_info, @storage, @savers, @update_mutex = nil
      end
    end

    def self.parse!(handler, *args, **request)
      if request.has_key? :config
        config = request[:config]
        request.delete :config
      else
        config = {}
      end
      spider = new config: config

      if args.present?
        spider.public_send(handler, *args)
      elsif request.present?
        spider.request_to(handler, url: request[:url], data: request[:data])
      else
        spider.public_send(handler)
      end
    ensure
      spider.browser.destroy_driver! if spider.instance_variable_get('@browser')
    end

    ###

    attr_reader :logger
    attr_accessor :with_info

    def initialize(engine = self.class.engine, config: {})
      @engine = engine || self.class.engine
      @config = self.class.config.deep_merge_excl(config, DMERGE_EXCLUDE)
      @pipelines = self.class.pipelines.map do |pipeline_name|
        klass = Pipeline.descendants.find { |kl| kl.name == pipeline_name }
        instance = klass.new
        instance.spider = self
        [pipeline_name, instance]
      end.to_h

      @logger = self.class.logger
      @savers = {}
    end

    def browser
      @browser ||= BrowserBuilder.build(@engine, @config, spider: self)
    end

    def request_to(handler, delay = nil, url:, data: {}, response_type: :html)
      raise InvalidUrlError, "Requested url is invalid: #{url}" unless URI.parse(url).is_a?(URI::HTTP)

      if @config[:skip_duplicate_requests] && !unique_request?(url)
        add_event(:duplicate_requests) if with_info
        logger.warn "Spider: request_to: not unique url: #{url}, skipped" and return
      end

      visited = delay ? browser.visit(url, delay: delay) : browser.visit(url)
      return unless visited

      public_send(handler, browser.current_response(response_type), **{ url: url, data: data })
    end

    def console(response = nil, url: nil, data: {})
      binding.pry
    end

    ###

    def storage
      # NOTE: for `.crawl!` uses shared thread safe Storage instance,
      # otherwise, each spider instance will have it's own Storage
      @storage ||= with_info ? self.class.storage : Storage.new
    end

    def unique?(scope, value)
      storage.unique?(scope, value)
    end

    def save_to(path, item, format:, position: true, append: false)
      @savers[path] ||= begin
        options = { format: format, position: position, append: append }
        if with_info
          self.class.savers[path] ||= Saver.new(path, **options)
        else
          Saver.new(path, **options)
        end
      end

      @savers[path].save(item)
    end

    ###

    def add_event(scope = :custom, event)
      self.class.add_event(scope, event) if with_info

      logger.info "Spider: new event (scope: #{scope}): #{event}" if scope == :custom
    end

    ###

    private

    def create_browser(engine, config = {})
      Tanakai::BrowserBuilder.build(engine, config, spider: self)
    end

    def unique_request?(url)
      options = @config[:skip_duplicate_requests]
      if options.instance_of?(Hash)
        scope = options[:scope] || :requests_urls
        if options[:check_only]
          storage.include?(scope, url) ? false : true
        else
          storage.unique?(scope, url) ? true : false
        end
      else
        storage.unique?(:requests_urls, url) ? true : false
      end
    end

    def send_item(item, options = {})
      logger.debug "Pipeline: starting processing item through #{@pipelines.size} #{'pipeline'.pluralize(@pipelines.size)}..."
      self.class.update(:items, :sent) if with_info

      @pipelines.each do |name, instance|
        item = options[name] ? instance.process_item(item, options: options[name]) : instance.process_item(item)
      end
    rescue StandardError => e
      logger.error "Pipeline: dropped: #{e.inspect} (#{e.backtrace.first}), item: #{item}"
      add_event(:drop_items_errors, e.inspect) if with_info
      false
    else
      self.class.update(:items, :processed) if with_info
      logger.info "Pipeline: processed: #{JSON.generate(item)}"
      true
    ensure
      if with_info
        logger.info "Info: items: sent: #{self.class.items[:sent]}, processed: #{self.class.items[:processed]}"
      end
    end

    def in_parallel(handler, urls, threads:, data: {}, delay: nil, engine: @engine, config: {}, response_type: :html)
      parts = urls.in_sorted_groups(threads, false)
      urls_count = urls.size

      all = []
      start_time = Time.now
      logger.info "Spider: in_parallel: starting processing #{urls_count} urls within #{threads} threads"

      parts.each do |part|
        all << Thread.new(part) do |part|
          Thread.current.abort_on_exception = true

          spider = self.class.new(engine, config: @config.deep_merge_excl(config, DMERGE_EXCLUDE))
          spider.with_info = true if with_info

          part.each do |url_data|
            if url_data.instance_of?(Hash)
              if url_data[:url].present? && url_data[:data].present?
                spider.request_to(handler, delay, **{ **url_data, response_type: response_type })
              else
                spider.public_send(handler, **url_data)
              end
            else
              spider.request_to(handler, delay, url: url_data, data: data, response_type: response_type)
            end
          end
        ensure
          spider.browser.destroy_driver! if spider.instance_variable_get('@browser')
        end

        sleep 0.5
      end

      all.each(&:join)
      logger.info "Spider: in_parallel: stopped processing #{urls_count} urls within #{threads} threads, total time: #{(Time.now - start_time).duration}"
    end
  end
end
