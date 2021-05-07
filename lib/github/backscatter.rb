require 'github/backscatter/storage'
require 'github/backscatter/location'
require 'github/backscatter/caller'
require 'github/backscatter/result'

# Public: Instrument methods for refactoring via graphite, redis, and Failbot.
module GitHub
  module Backscatter
    # Internal: enable/disable the entire backscatter system with this killswitch.
    # GitHub::Backscatter.disable / enable.
    #
    # However, for querying, use GitHub.backscatter_enabled?
    extend Killswitch

    # used by the failbot reporting of deprecation warnings
    # (see instrumentation)
    class DeprecationError < StandardError
    end

    # Public: allow overriding default behavior of `backscatter_fatal_deprecations?`
    attr_accessor :backscatter_fatal_deprecations

    # Public: Add a call of an instrumented method.
    #
    # called_method - the #caller stack trace of the called method
    # signature     - the 'Class#method' or 'Class.method' signature of the called method.
    #
    # Returns truthy if successful, raises GitHub::Backscatter::Storage::OperationFailed
    # on failure.
    def self.add(called_method, signature, relative_path)
      Storage.add(called_method, signature, relative_path)
    end

    # Public: Caller results for all called methods
    #
    # Returns an Array of Backscatter:Result objects containing all caller
    # information for methods instrumented by `backscatter_trace`.
    def self.results
      results = []
      Storage.called_methods.each_pair do |signature, location|
        results << Result.new(signature, location)
      end
      results
    end

    # Public: Gather recent `backscatter_measure` data
    #
    # since  - graphme start time specifier, default: '1hour'
    # window - bucket size for maximum computation, default: '5min'
    #
    # Returns a list of target name and measurement values
    def self.recent_measurements(since)
      data = GitHub.graphite.query(measurements_graph_formula('*'), since)
      return [] unless stats = data.summarize { |values| values.max }.stats

      stats.inject([]) do |results, entry|
        results << [ entry['target'], entry['datapoints'].first ]
      end.select {|value| value.last > 0}.sort_by { |value| -value.last }
    end

    # Public: suggest a `backscatter_trace` frequency for a method, based upon
    # graphite call data from `backscatter_measure`.
    #
    # calls_per_minute - number of times per minute the method was called
    #
    # Returns an integer frequency suitable for use as an argument to
    # `backscatter_trace`, or nil if no argument is necessary.
    def self.suggested_trace_frequency(calls_per_minute)
      return nil unless calls_per_minute > 600 # cap at 10 calls / second
      (calls_per_minute / 600.0).ceil
    end

    # Public: find the formula for the maximum call graph for a series, intended
    # to be used in constructing URLs to graphite.
    #
    # which - which particular `github.backscatter.count` series to look up
    #
    # Examples:
    #
    #   measurement_graph_formula('*')
    #   => "keepLastValue(summarize(github.backscatter.count.*,"1min","max"))"
    #
    # Returns a string for the Graphite formula to look up maximum call counts
    # for the specified series.
    def self.measurements_graph_formula(which)
      which.gsub!(/[^a-z0-9_#?=.!:"*]/i, '') # sanitize input
      formula = %Q{sortByName(substr(summarize(maximumAbove(github.backscatter.count.#{which},0),"1min","sum"),-1))}
      formula.gsub(/#/, '%23') # these are particularly problematic for Graphite in URLs
    end

    # Public: Instrument calls of calling method to Graphite
    #
    # Returns nil
    def backscatter_measure
      publish_call_information "measure"
    end

    # Public: Instrument callers of calling method to Redis
    #
    # Returns nil
    def backscatter_trace(sample_rate = nil)
      if sample_rate && sample_rate.to_i > 0
        return unless rand(sample_rate.to_i) == 0
      end

      publish_call_information "trace"
    end

    # Public: Deprecate callers of calling method, notify Failbot.
    #
    # message - String message to include in deprecation warning (optional)
    #
    # Returns nil.  Raises GitHub::Backscatter::DeprecationError when
    # `backscatter_fatal_deprecations?` is true (e.g., in development or testing).
    def backscatter_deprecate_method(message: nil)
      return unless GitHub.backscatter_enabled?
      emit_deprecation_warning(message)
      publish_call_information "deprecate_method", message: message
      raise DeprecationError.new(message) if backscatter_fatal_deprecations?
    end

    # Private: Send instrumented method information to appropriate subscribers
    #
    # message - String message to include in instrumentation
    #           (optional, only used for deprecation)
    #
    # Returns nil
    def publish_call_information(event_name, message: nil)
      return unless GitHub.backscatter_enabled?

      klass, signature, method_name = called_method_details

      GitHub.instrument "backscatter.#{event_name}", {
        :caller      => caller,
        :location    => caller[1],
        :class_name  => klass,
        :method_name => method_name,
        :signature   => signature,
        :message     => message,
      }
    end

    # Private: Emit a deprecation warning about my caller's caller.
    #
    # message - String message to include in deprecation warning (optional)
    #
    # Returns nil
    def emit_deprecation_warning(message = nil)
      signature = called_method_details[1]
      message = message ? ", #{message}" : ""

      warn "DEPRECATION WARNING: method `#{signature}' is deprecated" +
        message +
        " (see: #{caller[1]}). Called from: #{caller[2]}"
    end

    # Private: scrub a method name, making it safe to pass along to Graphite or
    # other tools that won't like spaces or similar characters.
    #
    # Retruns a String
    def scrub_method_name(name)
      name.gsub(/[^a-zA-Z0-9\-_]+/, "-")
    end

    # Private: Find the class name, method name and signature String for my great-grand-caller
    #
    # Returns an Array containing the  class name String, signature String, and
    # the method name String of my caller's caller's caller.
    def called_method_details
      method_name = scrub_method_name(caller_locations(1,3)[2].label)

      klass, signature = if self.class.name == 'Class'
        [self.name, "#{self.name}.#{method_name}"]
      else
        [self.class.name, "#{self.class.name}\##{method_name}"]
      end

      [klass, signature, method_name]
    end

    # Public: do `backscatter_deprecate_method` calls raise GitHub::Backscatter::DeprecationError ?
    #
    # Returns true if exceptions will be raised, false otherwise.  Defaults to
    # false, will be true when in the development or test run environment.  Can
    # be overridden by setting the value of the `backscatter_fatal_deprecations`
    # attribute.
    def backscatter_fatal_deprecations?
      return @backscatter_fatal_deprecations if defined? @backscatter_fatal_deprecations
      return true if Rails.development? || Rails.test?
      false
    end

    def self.deprecations
      @deprecations ||= GitHub::Grep.new.code_use "backscatter_deprecate_method",
        dirs: %w[app jobs lib]
    end

    def self.traces
      @traces ||= GitHub::Grep.new.code_use "backscatter_trace",
        dirs:   %w[app jobs lib],
        ignore: "app/views/devtools/backscatter/_measurements.html.erb"
    end

    def self.measures
      @measures ||= GitHub::Grep.new.code_use "backscatter_measure",
        dirs: %w[app jobs lib]
    end
  end
end
