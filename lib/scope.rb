require "minitest/unit"

module Scope
  # A test case class which provides nested contexts. Subclasses will have the "setup", "teardown", and
  # "should" methods available as class methods.
  class TestCase < MiniTest::Unit::TestCase
    # A map of test name => Context.
    def self.context_for_test() @context_for_test end

    def self.inherited(subclass)
      # Calling Unit::TestCase's inherited() method is important, as that's how it registers test suites.
      super

      subclass.instance_eval do
        # Pretend the whole test is wrapped in a context, so we can always code as if tests are in contexts.
        @contexts = [Context.new("")]
        @context_for_test = {}

        # The tests defined in this test case. MiniTest::Unit::TestCase sorts these methods randomly or
        # alphabetically. Let's run them in the order they were defined, as that's least surprising.
        def test_methods()
          tests = []
          stack = [@contexts.first]
          until stack.empty? do
            item = stack.pop
            stack += item.tests_and_subcontexts.reverse if item.is_a?(Context)
            tests << item if item.is_a?(String)
          end
          tests
        end
      end
    end

    def self.context(name, &block)
      parent = @contexts.last
      new_context = Context.new(name, parent)
      parent.tests_and_subcontexts << new_context
      @contexts << new_context
      block.call
      @contexts.pop
    end

    def self.should(name, &block)
      # When focus_enabled is true, we'll only be running the next should() block that gets defined.
      if @focus_enabled
        return unless @focus_next_test
        @focus_next_test = false
      end

      context_name = @contexts[1..-1].map { |context| context.name }.join(" ")
      context_name += " " unless context_name.empty?
      test_method_name = "#{context_name}should #{name}"
      define_method test_method_name, block
      @contexts.last.tests_and_subcontexts << test_method_name
      @context_for_test[test_method_name] = @contexts.last
    end

    def self.setup(&block) @contexts.last.setup= block end
    def self.teardown(&block) @contexts.last.teardown = block end

    # setup_once blocks are run just once for a context, and not on a per-test basis. They are useful
    # for integration tests with costly setup.
    def self.setup_once(&block) @contexts.last.setup_once = block end
    def self.teardown_once(&block) @contexts.last.teardown_once = block end

    # "Focuses" the next test that's defined after this method is called, ensuring that only that test is run.
    def self.focus
      # Since we're focusing only the next test, remove any tests which were already defined.
      context_for_test.values.uniq.each do |context|
        context.tests_and_subcontexts.reject! { |test| test.is_a?(String) }
      end
      @focus_enabled = true
      @focus_next_test = true
    end

    # run() is called by the MiniTest framework. This TestCase class is instantiated once per test method
    # defined, and then run() is called on each test case instance.
    def run(test_runner)
      test_name = self.__name__
      context = self.class.context_for_test[test_name]
      result = nil
      begin
        # Unit::TestCase's implementation of run() invokes the test method with exception handling.
        context.run_setup_and_teardown(self, test_name) { result = super }
      rescue *MiniTest::Unit::TestCase::PASSTHROUGH_EXCEPTIONS
        raise
      rescue Exception => error
        result = test_runner.puke(self.class, self.__name__, error)
      end
      result
    end
  end

  # A context keeps track of the tests defined inside of it as well as its setup and teardown blocks.
  class Context
    attr_reader :name, :parent_context
    # We keep both tests and subcontexts in the same array because we need to know what the very last thing
    # to execute inside of this context is, for the purpose of calling teardown_once at the correct time.
    attr_accessor :tests_and_subcontexts
    attr_accessor :setup, :teardown, :setup_once, :teardown_once

    def initialize(name, parent_context = nil)
      @name = name
      @parent_context = parent_context
      self.tests_and_subcontexts = []
    end

    # Runs the setup work for this context and any parent contexts, yields to the block (which should invoke
    # the actual test method), and then completes the teardown work.
    def run_setup_and_teardown(test_case_instance, test_name)
      contexts = ([self] + ancestor_contexts).reverse
      # We're using instance_eval so that instance vars set by the block are created on the test_case_instance
      contexts.each { |context| test_case_instance.instance_eval(&context.setup_once) if context.setup_once }
      contexts.each { |context| test_case_instance.instance_eval(&context.setup) if context.setup }
      yield
      contexts.reverse!
      contexts.each { |context| test_case_instance.instance_eval(&context.teardown) if context.teardown }

      # If this is the last context being run in any parent contexts, run their teardown_once blocks.
      if tests_and_subcontexts.last == test_name
        test_case_instance.instance_eval(&teardown_once) if teardown_once
        descendant_context = self
        ancestor_contexts.each do |ancestor|
          break unless ancestor.tests_and_subcontexts.last == descendant_context
          test_case_instance.instance_eval(&ancestor.teardown_once) if ancestor.teardown_once
          descendant_context = ancestor
        end
      end
    end

    def ancestor_contexts
      ancestors = []
      parent = self
      ancestors << parent while (parent = parent.parent_context)
      ancestors
    end

    def teardown_once=(block) @teardown_once = run_only_once(block) end
    def setup_once=(block) @setup_once = run_only_once(block) end

    private
    def run_only_once(block)
      has_run = false
      Proc.new { instance_eval(&block) unless has_run; has_run = true }
    end
  end
end