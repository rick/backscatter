require_relative "../test_helper"

class BackscatterTestVictim
  attr_reader :file, :line

  include GitHub::Backscatter
  extend GitHub::Backscatter

  def self.file
    @@file
  end

  def self.line
    @@line
  end

  def self.the_measured_class_method
    @@file, @@line = __FILE__, __LINE__ + 1
    backscatter_measure
  end

  def self.the_traced_class_method
    @@file, @@line = __FILE__, __LINE__ + 1
    backscatter_trace
  end

  def self.the_deprecated_class_method
    @@file, @@line = __FILE__, __LINE__ + 1
    backscatter_deprecate_method
  end

  def the_measured_method
    @file, @line = __FILE__, __LINE__ + 1
    backscatter_measure
  end

  define_method "a difficult method" do
    @file, @line = __FILE__, __LINE__ + 1
    backscatter_measure
  end

  def the_traced_method(sample_rate = nil)
    @file, @line = __FILE__, __LINE__ + 1
    backscatter_trace(sample_rate)
  end

  def the_deprecated_method
    @file, @line = __FILE__, __LINE__ + 1
    backscatter_deprecate_method
  end

  def the_deprecated_message_method
    @file, @line = __FILE__, __LINE__ + 1
    backscatter_deprecate_method(message: "do OTHER THING instead")
  end

  # We expect `#warn` to be called from this test victim when the backscatter
  # libs are included, and we'd prefer not to emit warnings in the test suite
  # output.  Rather than stubbing, etc., we'll just define them as no-ops here
  # for the instance- and class-method test paths.
  def self.warn(*args)
  end

  def warn(*args)
  end
end

def stub_graphite_connection_to_return(json_data)
  request_stub = Faraday::Adapter::Test::Stubs.new do |stub|
    stub.get('/render') {[200, {}, json_data]}
  end

  stub_connection = Faraday.new do |builder|
    builder.adapter :test, request_stub do |stub|
    end
  end

  GitHub.graphite.stubs(:connection).returns(stub_connection)
end

unless GitHub.enterprise?
  context GitHub::Backscatter do
    fixtures do
      @victim = BackscatterTestVictim.new
      @victim.backscatter_fatal_deprecations = false
      BackscatterTestVictim.backscatter_fatal_deprecations = false
    end

    setup do
      GitHub::Backscatter.results.collect(&:signature).each do |signature|
        GitHub::Backscatter::Storage.delete_called_method(signature)
      end
    end

    test "can retrieve stored caller data" do
      GitHub::Backscatter.add 'called_2', 'FakeClass#called_1', '/app/models/caller_1.rb:23'
      GitHub::Backscatter.add 'called_1', 'FakeClass#called_1', '/app/models/caller_1.rb:23'
      GitHub::Backscatter.add 'called_1', 'FakeClass#called_1', '/app/models/caller_2.rb:12'
      GitHub::Backscatter.add 'called_2', 'FakeClass#called_2', '/app/models/caller_3.rb:34'

      results = GitHub::Backscatter.results
      assert_equal ['FakeClass#called_1', 'FakeClass#called_2'], results.collect(&:signature)

      callers = results.collect(&:callers).flatten
      assert_equal [2, 1, 1], callers.collect(&:count)
      assert_equal [
        "/app/models/caller_1.rb:23",
        "/app/models/caller_2.rb:12",
        "/app/models/caller_3.rb:34"
      ], callers.collect(&:location_string)
    end

    context 'gathering recent measurements' do
      test "returns an empty list when there is no graphite data available" do
        stub_graphite_connection_to_return JSON.dump(nil)
        assert_equal [], GitHub::Backscatter.recent_measurements('-1month')
      end

      test "returns an empty list when no measurements are available" do
        stub_graphite_connection_to_return JSON.dump([])
        assert_equal [], GitHub::Backscatter.recent_measurements('-1month')
      end

      test "returns a sorted list of target + measurement pairs" do
        json_data = JSON.dump(
          [
            {
              "target"    => "Organization#owned_by?",
              "datapoints"=> [ [24.0, 1380826050], [28.0, 1380826060], [25.0, 1380826070] ]
            },
            {
              "target"    => "Organization#owners",
              "datapoints"=> [ [0.1, 1380826050], [0.2, 1380826060], [0.0, 1380826070] ]
            },
            {
              "target"    => "Organization#owners_team",
              "datapoints"=> [ [0.1, 1380826050], [80.5, 1380826060], [0.0, 1380826070] ]
            },
            {
              "target"    => "FooClass-class_method",
              "datapoints"=> [ [0.0, 1380826050], [0.0, 1380826060], [0.0, 1380826070] ]
            },
            {
              "target"    => "Organization#member?",
              "datapoints"=> [ [24.0, 1380826050], [14606.0, 1380826060], [25.0, 1380826070] ]
            },
            {
              "target"    => "Repository#owned_by?",
              "datapoints"=> [ [24.0, 1380826050], [382.0, 1380826060], [25.0, 1380826070] ]
            },
            {
              "target"    => "Organization#abs_owners",
              "datapoints"=> [ [0.0, 1380826050], [0.0, 1380826060], [0.0, 1380826070] ]
            },
          ])

        stub_graphite_connection_to_return json_data

        assert_equal [
          ["Organization#member?",    14606.0],
          ["Repository#owned_by?",      382.0],
          ["Organization#owners_team",   80.5],
          ["Organization#owned_by?",     28.0],
          ["Organization#owners",         0.2],
        ], GitHub::Backscatter.recent_measurements('-1month')
      end

      test "omits any data which had no measurements in the specified time period" do
        json_data = JSON.dump(
          [
            {
              "target"    => "Organization#owned_by?",
              "datapoints"=> [ [24.0, 1380826050], [28.0, 1380826060], [25.0, 1380826070] ]
            },
            {
              "target"    => "Organization#owners",
              "datapoints"=> [ [0.1, 1380826050], [0.2, 1380826060], [0.0, 1380826070] ]
            },
            {
              "target"    => "Organization#owners_team",
              "datapoints"=> [ [nil, 1380826050], [nil, 1380826060], [nil, 1380826070] ]
            },
            {
              "target"    => "FooClass-class_method",
              "datapoints"=> [ [nil, 1380826050], [nil, 1380826060], [nil, 1380826070] ]
            },
            {
              "target"    => "Organization#member?",
              "datapoints"=> [ [24.0, 1380826050], [14606.0, 1380826060], [25.0, 1380826070] ]
            },
            {
              "target"    => "Repository#owned_by?",
              "datapoints"=> [ [24.0, 1380826050], [382.0, 1380826060], [25.0, 1380826070] ]
            },
            {
              "target"    => "Organization#abs_owners",
              "datapoints"=> [ [0.0, 1380826050], [0.0, 1380826060], [0.0, 1380826070] ]
            },
          ])

        stub_graphite_connection_to_return json_data

        assert_equal [
          ["Organization#member?",    14606.0],
          ["Repository#owned_by?",      382.0],
          ["Organization#owned_by?",     28.0],
          ["Organization#owners",         0.2],
        ], GitHub::Backscatter.recent_measurements('-1month')
      end
    end

    context :backscatter_measure do
      test "instruments with backscatter.measure" do
        events = subscribe "backscatter.measure"
        @victim.the_measured_method
        assert event = events.pop, "a backscatter.measure event was expected"
      end

      test "increments stats when called" do
        GitHub.stats.expects(:increment).with("backscatter.count.BackscatterTestVictim#the_measured_method")
        @victim.the_measured_method
      end

      test "scrubs the method name for GitHub stats (see github/github#/30749)" do
        GitHub.stats.expects(:increment).with("backscatter.count.BackscatterTestVictim#block-in-class-BackscatterTestVictim-")
        @victim.send("a difficult method")
      end

      test "passes the call stack as :caller when instrumenting" do
        events = subscribe "backscatter.measure"
        @victim.the_measured_method

        assert event = events.pop, "a backscatter.measure event was expected"
        assert event.payload[:caller].size > 2
        assert_match /:in `backscatter_measure'/, event.payload[:caller].first
        assert_equal "#{@victim.file}:#{@victim.line}:in `the_measured_method'",
          event.payload[:caller][1]
      end

      test "passes the called method's location as :location when instrumenting a class method" do
        events = subscribe "backscatter.measure"
        BackscatterTestVictim.the_measured_class_method
        assert event = events.pop, "a backscatter.measure event was expected"
        assert_equal "#{BackscatterTestVictim.file}:#{BackscatterTestVictim.line}:in `the_measured_class_method'", event.payload[:location]
      end

      test "passes the called method's location as :location when instrumenting" do
        events = subscribe "backscatter.measure"
        @victim.the_measured_method
        assert event = events.pop, "a backscatter.measure event was expected"
        assert_equal "#{@victim.file}:#{@victim.line}:in `the_measured_method'", event.payload[:location]
      end

      test "passes the call stack as :caller when instrumenting a class method" do
        events = subscribe "backscatter.measure"
        BackscatterTestVictim.the_measured_class_method

        assert event = events.pop, "a backscatter.measure event was expected"
        assert event.payload[:caller].size > 2
        assert_match /:in `backscatter_measure'/, event.payload[:caller].first
        assert_equal "#{BackscatterTestVictim.file}:#{BackscatterTestVictim.line}:in `the_measured_class_method'",
          event.payload[:caller][1]
      end

      test "passes the name of the class under inspection as :class_name when instrumenting" do
        events = subscribe "backscatter.measure"
        @victim.the_measured_method
        assert event = events.pop, "a backscatter.measure event was expected"
        assert_equal 'BackscatterTestVictim', event.payload[:class_name]
      end

      test "passes the name of the Class under inspection as :class_name when instrumenting a class method" do
        events = subscribe "backscatter.measure"
        BackscatterTestVictim.the_measured_class_method
        assert event = events.pop, "a backscatter.measure event was expected"
        assert_equal 'BackscatterTestVictim', event.payload[:class_name]
      end

      test "passes the calling method name as :method_name when instrumenting" do
        events = subscribe "backscatter.measure"
        @victim.the_measured_method
        assert event = events.pop, "a backscatter.measure event was expected"
        assert_equal 'the_measured_method', event.payload[:method_name]
      end

      test "passes the calling method name as :method_name when instrumenting a class method" do
        events = subscribe "backscatter.measure"
        BackscatterTestVictim.the_measured_class_method
        assert event = events.pop, "a backscatter.measure event was expected"
        assert_equal 'the_measured_class_method', event.payload[:method_name]
      end

      test "passes the caller's string signature as :signature when instrumenting" do
        events = subscribe "backscatter.measure"
        @victim.the_measured_method
        assert event = events.pop, "a backscatter.measure event was expected"
        assert_equal 'BackscatterTestVictim#the_measured_method', event.payload[:signature]
      end

      test "passes the caller's string signature as :signature when instrumenting a class method" do
        events = subscribe "backscatter.measure"
        BackscatterTestVictim.the_measured_class_method
        assert event = events.pop, "a backscatter.measure event was expected"
        assert_equal 'BackscatterTestVictim.the_measured_class_method', event.payload[:signature]
      end
    end

    context :backscatter_trace do
      test "instruments with backscatter.trace" do
        events = subscribe "backscatter.trace"
        @victim.the_traced_method
        assert event = events.pop, "a backscatter.trace event was expected"
      end

      test "always runs when 0 or bad sample rate is specified" do
        events = subscribe "backscatter.trace"
        @victim.the_traced_method(0)
        @victim.the_traced_method("0")
        @victim.the_traced_method(-1)
        @victim.the_traced_method(false)
        @victim.the_traced_method(nil)
        assert events.pop, "a backscatter.trace event was expected"
      end

      test "does not run when a sample rate is specified and the dice are unfavorable" do
        events = subscribe "backscatter.trace"
        @victim.stubs(:rand).returns(1)
        @victim.the_traced_method(100)
        assert !events.pop, "a backscatter.trace event was not expected"
      end

      test "runs when a sample rate is specified and the dice are favorable" do
        events = subscribe "backscatter.trace"
        @victim.stubs(:rand).returns(0)
        @victim.the_traced_method(100)
        assert events.pop, "a backscatter.trace event was expected"
      end

      test "passes the call stack as :caller when instrumenting" do
        events = subscribe "backscatter.trace"
        @victim.the_traced_method

        assert event = events.pop, "a backscatter.trace event was expected"
        assert event.payload[:caller].size > 2
        assert_match /:in `backscatter_trace'/, event.payload[:caller].first
        assert_equal "#{@victim.file}:#{@victim.line}:in `the_traced_method'",
          event.payload[:caller][1]
      end

      test "passes the call stack as :caller when instrumenting a class method" do
        events = subscribe "backscatter.trace"
        BackscatterTestVictim.the_traced_class_method

        assert event = events.pop, "a backscatter.trace event was expected"
        assert event.payload[:caller].size > 2
        assert_match /:in `backscatter_trace'/, event.payload[:caller].first
        assert_equal "#{BackscatterTestVictim.file}:#{BackscatterTestVictim.line}:in `the_traced_class_method'",
          event.payload[:caller][1]
      end

      test "passes the called method's location as :location when instrumenting" do
        events = subscribe "backscatter.trace"
        @victim.the_traced_method
        assert event = events.pop, "a backscatter.trace event was expected"
        assert_equal "#{@victim.file}:#{@victim.line}:in `the_traced_method'", event.payload[:location]
      end

      test "passes the called method's location as :location when instrumenting a class method" do
        events = subscribe "backscatter.trace"
        BackscatterTestVictim.the_traced_class_method
        assert event = events.pop, "a backscatter.trace event was expected"
        assert_equal "#{BackscatterTestVictim.file}:#{BackscatterTestVictim.line}:in `the_traced_class_method'", event.payload[:location]
      end

      test "passes the name of the class under inspection as :class_name when instrumenting" do
        events = subscribe "backscatter.trace"
        @victim.the_traced_method
        assert event = events.pop, "a backscatter.trace event was expected"
        assert_equal 'BackscatterTestVictim', event.payload[:class_name]
      end

      test "passes the name of the Class under inspection as :class_name when instrumenting a class method" do
        events = subscribe "backscatter.trace"
        BackscatterTestVictim.the_traced_class_method
        assert event = events.pop, "a backscatter.trace event was expected"
        assert_equal 'BackscatterTestVictim', event.payload[:class_name]
      end

      test "passes the calling method name as :method_name when instrumenting" do
        events = subscribe "backscatter.trace"
        @victim.the_traced_method
        assert event = events.pop, "a backscatter.trace event was expected"
        assert_equal 'the_traced_method', event.payload[:method_name]
      end

      test "passes the calling method name as :method_name when instrumenting a class method" do
        events = subscribe "backscatter.trace"
        BackscatterTestVictim.the_traced_class_method
        assert event = events.pop, "a backscatter.trace event was expected"
        assert_equal 'the_traced_class_method', event.payload[:method_name]
      end

      test "passes the caller's string signature as :signature when instrumenting" do
        events = subscribe "backscatter.trace"
        @victim.the_traced_method
        assert event = events.pop, "a backscatter.trace event was expected"
        assert_equal 'BackscatterTestVictim#the_traced_method', event.payload[:signature]
      end

      test "passes the caller's string signature as :signature when instrumenting a class method" do
        events = subscribe "backscatter.trace"
        BackscatterTestVictim.the_traced_class_method
        assert event = events.pop, "a backscatter.trace event was expected"
        assert_equal 'BackscatterTestVictim.the_traced_class_method', event.payload[:signature]
      end

      test "does not raise an error when storage backend fails" do
        GitHub::Backscatter.stubs(:add).raises(GitHub::Backscatter::Storage::OperationFailed)
        assert_nothing_raised do
          @victim.the_traced_method
        end
      end
    end

    context :backscatter_deprecate_method do
      test "emits a deprecation warning" do
        @victim.backscatter_fatal_deprecations = false
        @victim.expects(:warn).with do |warning|
          warning =~ %r{`BackscatterTestVictim#the_deprecated_method'.*in `the_deprecated_method'.*#{__FILE__}}
        end
        @victim.the_deprecated_method
      end

      test "emits a deprecation warning when deprecating a class method" do
        BackscatterTestVictim.backscatter_fatal_deprecations = false
        BackscatterTestVictim.expects(:warn).with do |warning|
          warning =~ %r{`BackscatterTestVictim\.the_deprecated_class_method'.*in `the_deprecated_class_method'.*#{__FILE__}}
        end

        BackscatterTestVictim.the_deprecated_class_method
      end

      test "emits a deprecation warning with an explanation" do
        @victim.backscatter_fatal_deprecations = false
        @victim.expects(:warn).with do |warning|
          warning =~ %r{`BackscatterTestVictim#the_deprecated_message_method'.*do OTHER THING instead.*in `the_deprecated_message_method'.*#{__FILE__}}
        end
        @victim.the_deprecated_message_method
      end

      test "instruments with backscatter.deprecate_method" do
        @victim.backscatter_fatal_deprecations = false
        events = subscribe "backscatter.deprecate_method"
        @victim.the_deprecated_method
        assert event = events.pop, "a backscatter.deprecate_method event was expected"
      end

      test "raises an exception under fatal deprecations" do
        @victim.backscatter_fatal_deprecations = true
        assert_raises GitHub::Backscatter::DeprecationError do
          @victim.the_deprecated_method
        end
      end

      test "raises an exception when deprecating a class method under fatal deprecations" do
        BackscatterTestVictim.backscatter_fatal_deprecations = true
        assert_raises GitHub::Backscatter::DeprecationError do
          BackscatterTestVictim.the_deprecated_class_method
        end
      end

      test "raises an exception with an explanation under fatal deprecations" do
        @victim.backscatter_fatal_deprecations = true

        error = nil
        begin
          @victim.the_deprecated_message_method
        rescue GitHub::Backscatter::DeprecationError => e
          error = e
        end

        assert error, "expected a GitHub::Backscatter::DeprecationError to be raised"
        assert_equal "do OTHER THING instead", error.message
      end

      test "instruments deprecated method under fatal deprecations" do
        @victim.backscatter_fatal_deprecations = true

        events = subscribe "backscatter.deprecate_method"
        assert_raises GitHub::Backscatter::DeprecationError do
          @victim.the_deprecated_method
        end
        assert event = events.pop, "a backscatter.deprecate_method event was expected"
      end

      test "passes the call stack as :caller when instrumenting" do
        events = subscribe "backscatter.deprecate_method"
        @victim.the_deprecated_method

        assert event = events.pop, "a backscatter.deprecate_method event was expected"
        assert event.payload[:caller].size > 2
        assert_match /:in `backscatter_deprecate_method'/, event.payload[:caller].first
        assert_equal "#{@victim.file}:#{@victim.line}:in `the_deprecated_method'",
          event.payload[:caller][1]
      end

      test "passes the call stack as :caller when instrumenting a class method" do
        events = subscribe "backscatter.deprecate_method"
        BackscatterTestVictim.the_deprecated_class_method

        assert event = events.pop, "a backscatter.deprecate_method event was expected"
        assert event.payload[:caller].size > 2
        assert_match /:in `backscatter_deprecate_method'/, event.payload[:caller].first
        assert_equal "#{BackscatterTestVictim.file}:#{BackscatterTestVictim.line}:in `the_deprecated_class_method'",
          event.payload[:caller][1]
      end

      test "passes the called method's location as :location when instrumenting" do
        events = subscribe "backscatter.deprecate_method"
        @victim.the_deprecated_method
        assert event = events.pop, "a backscatter.deprecate_method event was expected"
        assert_equal "#{@victim.file}:#{@victim.line}:in `the_deprecated_method'", event.payload[:location]
      end

      test "passes the called method's location as :location when instrumenting a class method" do
        events = subscribe "backscatter.deprecate_method"
        BackscatterTestVictim.the_deprecated_class_method
        assert event = events.pop, "a backscatter.deprecate_method event was expected"
        assert_equal "#{BackscatterTestVictim.file}:#{BackscatterTestVictim.line}:in `the_deprecated_class_method'", event.payload[:location]
      end

      test "passes the name of the class under inspection as :class_name when instrumenting" do
        events = subscribe "backscatter.deprecate_method"
        @victim.the_deprecated_method
        assert event = events.pop, "a backscatter.deprecate_method event was expected"
        assert_equal 'BackscatterTestVictim', event.payload[:class_name]
      end

      test "passes the name of the Class under inspection as :class_name when instrumenting a class method" do
        events = subscribe "backscatter.deprecate_method"
        BackscatterTestVictim.the_deprecated_class_method
        assert event = events.pop, "a backscatter.deprecate_method event was expected"
        assert_equal 'BackscatterTestVictim', event.payload[:class_name]
      end

      test "passes the calling method name as :method_name when instrumenting" do
        events = subscribe "backscatter.deprecate_method"
        @victim.the_deprecated_method
        assert event = events.pop, "a backscatter.deprecate_method event was expected"
        assert_equal 'the_deprecated_method', event.payload[:method_name]
      end

      test "passes the calling method name as :method_name when instrumenting a class method" do
        events = subscribe "backscatter.deprecate_method"
        BackscatterTestVictim.the_deprecated_class_method
        assert event = events.pop, "a backscatter.deprecate_method event was expected"
        assert_equal 'the_deprecated_class_method', event.payload[:method_name]
      end

      test "passes the caller's string signature as :signature when instrumenting" do
        events = subscribe "backscatter.deprecate_method"
        @victim.the_deprecated_method
        assert event = events.pop, "a backscatter.deprecate_method event was expected"
        assert_equal 'BackscatterTestVictim#the_deprecated_method', event.payload[:signature]
      end

      test "passes the caller's string signature as :signature when instrumenting a class method" do
        events = subscribe "backscatter.deprecate_method"
        BackscatterTestVictim.the_deprecated_class_method
        assert event = events.pop, "a backscatter.deprecate_method event was expected"
        assert_equal 'BackscatterTestVictim.the_deprecated_class_method', event.payload[:signature]
      end

      test "passes the called method's deprecation message as :message when instrumenting" do
        events = subscribe "backscatter.deprecate_method"
        @victim.the_deprecated_message_method
        assert event = events.pop, "a backscatter.deprecate_method event was expected"
        assert_equal "do OTHER THING instead", event.payload[:message]
      end
    end

    test "deprecations raise exceptions in dev mode" do
      Rails.stubs(:development?).returns(true)
      Rails.stubs(:test?).returns(false)
      Rails.stubs(:production?).returns(false)
      assert BackscatterTestVictim.new.backscatter_fatal_deprecations?, "deprecations should raise exceptions in dev mode"
    end

    test "deprecations raise exceptions in test mode" do
      assert BackscatterTestVictim.new.backscatter_fatal_deprecations?, "deprecations should raise exceptions in test mode"
    end

    test "deprecations do not raise exceptions in production mode" do
      Rails.stubs(:development?).returns(false)
      Rails.stubs(:test?).returns(false)
      Rails.stubs(:production?).returns(true)
      refute BackscatterTestVictim.new.backscatter_fatal_deprecations?, "deprecations should not raise exceptions in prod mode"
    end

    context "computing suggested backscatter_trace frequency" do
      test "returns nil if the per-minute call count is <= 600" do
        assert_nil GitHub::Backscatter.suggested_trace_frequency(600)
      end

      test "returns a frequency that caps calls to 10 per second" do
        assert_equal 10, GitHub::Backscatter.suggested_trace_frequency(6000)
        assert_equal 15, GitHub::Backscatter.suggested_trace_frequency(9000)
        assert_equal 1000, GitHub::Backscatter.suggested_trace_frequency(600000)
      end

      test "rounds up when computed frequency is non-integral" do
        assert_equal 11, GitHub::Backscatter.suggested_trace_frequency(6001)
        assert_equal 16, GitHub::Backscatter.suggested_trace_frequency(9001)
        assert_equal 1001, GitHub::Backscatter.suggested_trace_frequency(600001)
      end
    end
  end
end
