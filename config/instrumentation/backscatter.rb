# Record information about methods watched by GitHub::Backscatter

# Count calls of `backscatter_measure`-instrumented methods by shipping data to
# Graphite.  This is intended to be a low-latency high-throughput way to see just
# how often a particular method is called.  Then decisions can be made about how
# often to instrument with higher-latency methods.
GitHub.subscribe 'backscatter.measure' do |name, start, ending, transaction_id, payload|
  signature = payload[:signature].gsub(/(\.|::)/, '-') # encode class method '.'s and '::'s
  GitHub.stats.increment "backscatter.count.#{signature}"
end

# Capture caller and count information for `backscatter_trace`-instrumented methods
# and ship to transient_redis for analysis.
GitHub.subscribe 'backscatter.trace' do |name, start, ending, transaction_id, payload|
  begin
    stack, location, signature = payload.values_at :caller, :location, :signature
    if loc = GitHub::Backscatter::Location.from_stack(stack, location)
      if loc.well_formed?
        GitHub::Backscatter.add location, signature, loc.relative_file_path
      end
    end
  rescue GitHub::Backscatter::Storage::OperationFailed
  end
end

# Report calls of `backscatter_deprecate_method`-instrumented methods via a non-
# Fatal message to Failbot.
GitHub.subscribe 'backscatter.deprecate_method' do |name, start, ending, transaction_id, payload|
  stack, location, signature = payload.values_at :caller, :location, :signature

  called_method  = GitHub::Backscatter::Location.new location
  calling_method = GitHub::Backscatter::Location.from_stack stack, location

  args = {
    :instrumentation_payload => payload,
    :called_method           => called_method.relative_file_path,
    :called_method_url       => called_method.github_link(GitHub.current_sha),
    :caller                  => calling_method.relative_file_path,
    :caller_url              => calling_method.github_link(GitHub.current_sha),
    :deprecation_message     => payload[:message]
  }

  Failbot.push args

  boom = GitHub::Backscatter::DeprecationError.new("call to #{signature}")
  boom.set_backtrace(caller)
  Failbot.report_trace(boom)
end
