require 'rack/head'

class Grape::Middleware::Logger
  module RackHeadOverride
    def call(env)
      response = super
      status, _, rack = *response
      # rescue rack response in case non-json output is given
      response_object = JSON.parse(rack.body.try(:first) || '{}').with_indifferent_access rescue {}

      if env && env['grape.middleware.log'].present?
        logger = env['grape.middleware.logger']
        log_sanitizer = env['grape.middleware.log_sanitizer']
        log = sanitize(env['grape.middleware.log'], &log_sanitizer)
        log[:status] = response[0]
        log[:runtime] = "#{((log[:end_time] - log[:start_time]) * 1000).round(2)}ms"

        log[:exception] = response_object[:code] if response_object[:code].present?
        log[:message] = response_object[:error] if response_object[:error].present?

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
          logger.info "Completed #{status} in #{runtime}ms"
          logger.info ''
        else
          logger.info log.to_json
        end
      end

      response
    end

    private

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
end

Rack::Head.prepend Grape::Middleware::Logger::RackHeadOverride
