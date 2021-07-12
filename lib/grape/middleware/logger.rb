require 'logger'
require 'grape'

class Grape::Middleware::Logger < Grape::Middleware::Globals
  BACKSLASH = '/'.freeze

  attr_reader :logger

  class << self
    attr_accessor :logger, :filter, :headers, :logs

    def default_logger
      default = Logger.new(STDOUT)
      default.formatter = ->(*args) { args.last.to_s << "\n".freeze }
      default
    end

    def sanitize(input, &sanitizer)
      output = if input.is_a?(Hash)
        input.map do |k, v|
          v = send(:sanitize, sanitizer.call(k, v), &sanitizer)
          [k, v]
        end.to_h
      elsif input.is_a?(Array)
        input.map do |v|
          send(:sanitize, sanitizer.call(nil, v), &sanitizer)
        end
      else
        sanitizer.call(nil, input)
      end
      output
    end
  end

  def initialize(_, options = {})
    super
    @options[:filter] ||= self.class.filter
    @options[:headers] ||= self.class.headers
    @logger = options[:logger] || self.class.logger || self.class.default_logger
    @log_sanitizer = options[:log_sanitizer] || Proc.new { |v| k.to_s =~ /password/ ? '[password]' : v }
    @is_render_json = options[:is_render_json] || false
    reset_log!
  end

  def before
    reset_log! # Reset log object

    super

    @log.merge!({
      start_time: start_time,
      request_method: env[Grape::Env::GRAPE_REQUEST].request_method,
      path: env[Grape::Env::GRAPE_REQUEST].path,
      processed: processed_by,
      parameters: parameters,
      remote_ip: env[Grape::Env::GRAPE_REQUEST].env['REMOTE_ADDR'],
    })
    @log[:headers] = headers if @options[:headers]
    @log[:trace_id] = env[:trace_id]

    logger = @logger
    log_sanitizer = @log_sanitizer
    log = self.class.sanitize(@log, &log_sanitizer)

    unless log[:render_json]
      logger.info ''
      logger.info %Q(Started %s "%s" at %s) % [
        log[:request_method],
        log[:path],
        log[:start_time].to_s
      ]
      logger.info %Q(Processing by #{log[:processed]})
      logger.info %Q(  Parameters: #{log[:parameters]})
      logger.info %Q(  Headers: #{log[:headers]}) if log[:headers].present?
      logger.info %Q(  Remote IP: #{log[:remote_ip]})
      logger.info %Q(  Trace ID: #{log[:trace_id]})
      logger.info ''
    else
      logger.info log.to_json
    end
  end

  # @note Error and exception handling are required for the +after+ hooks
  #   Exceptions are logged as a 500 status and re-raised
  #   Other "errors" are caught, logged and re-thrown
  def call!(env)
    @env = env
    before
    error = catch(:error) do
      begin
        @app_response = @app.call(@env)
      rescue => e
        if @options[:around_exception] && @options[:around_exception].is_a?(Proc)
          e = @options[:around_exception].call(e)
        end
        after_exception(e)
        raise e
      end
      nil
    end
    if error
      after_failure(error)
      throw(:error, error)
    else
      after
    end
    @app_response
  end

  def after
    @log[:end_time] = Time.now
    env['grape.middleware.logger'] = @logger
    env['grape.middleware.log'] = @log
    env['grape.middleware.log_sanitizer'] = @log_sanitizer
  end

  #
  # Helpers
  #

  def after_exception(e)
    @log[:exception] = %Q(#{e.class.name}: #{e.message})
    after
  end

  def after_failure(error)
    @log[:message] = error[:message] if error[:message]
    after
  end

  def parameters
    request_params = env[Grape::Env::GRAPE_REQUEST_PARAMS].to_hash
    request_params.merge! env[Grape::Env::RACK_REQUEST_FORM_HASH] if env[Grape::Env::RACK_REQUEST_FORM_HASH]
    request_params.merge! env['action_dispatch.request.request_parameters'] if env['action_dispatch.request.request_parameters']
    if @options[:filter]
      @options[:filter].filter(request_params)
    else
      request_params
    end
  end

  def headers
    request_headers = env[Grape::Env::GRAPE_REQUEST_HEADERS].to_hash
    return Hash[request_headers.sort] if @options[:headers] == :all

    headers_needed = Array(@options[:headers])
    result = {}
    headers_needed.each do |need|
      result.merge!(request_headers.select { |key, value| need.to_s.casecmp(key).zero? })
    end
    Hash[result.sort]
  end

  def start_time
    @start_time ||= Time.now
  end

  def processed_by
    endpoint = env[Grape::Env::API_ENDPOINT]
    result = []
    if endpoint.namespace == BACKSLASH
      result << ''
    else
      result << endpoint.namespace
    end
    result.concat endpoint.options[:path].map { |path| path.to_s.sub(BACKSLASH, '') }
    endpoint.options[:for].to_s << result.join(BACKSLASH)
  end

  def reset_log!
    @log = { render_json: @is_render_json }
  end
end

require_relative 'logger/railtie' if defined?(Rails)

require_relative 'logger/rack_head_override' if defined?(Rack::Head)
