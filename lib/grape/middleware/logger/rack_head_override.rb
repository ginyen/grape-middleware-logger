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
        log = Grape::Middleware::Logger.sanitize(env['grape.middleware.log'], &log_sanitizer)
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
          logger.info %Q(Processed by #{log[:processed]})
          logger.info "Completed #{log[:status]} in #{log[:runtime]}ms"
          logger.info ''
        else
          logger.info log.to_json
        end
      end

      response
    end
  end
end

Rack::Head.prepend Grape::Middleware::Logger::RackHeadOverride
