class Pry

  # The list of configuration options.
  ConfigOptions = [:input, :output, :commands, :print,
                   :default_prompt, :hooks]

  attr_accessor *ConfigOptions
  
  # Create a new `Pry` object.
  # @param [Hash] options The optional configuration parameters.
  # @option options [#read] :input The object to use for input. (see input.rb)
  # @option options [#puts] :output The object to use for output. (see output.rb)
  # @option options [#commands] :commands The object to use for 
  #   commands. (see commands.rb)
  # @option options [Hash] :hooks The defined hook Procs (see hooks.rb)
  # @option options [Array<Proc>] :default_prompt The array of Procs
  #   to use for the prompts.
  # @option options [Proc] :print The Proc to use for the 'print' componenent of the REPL
  def initialize(options={})

    default_options = ConfigOptions.each_with_object({}) { |v, h| h[v] = Pry.send(v) }
    default_options.merge!(options)

    ConfigOptions.each do |key|
      instance_variable_set("@#{key}", default_options[key])
    end
  end

  # Get nesting data.
  # This method should not need to be accessed directly.
  # @return [Array] The unparsed nesting information.
  def nesting
    self.class.nesting
  end

  # Set nesting data.
  # This method should not need to be accessed directly.
  # @param v nesting data.
  def nesting=(v)
    self.class.nesting = v
  end

  # Execute the hook `hook_name`, if it is defined.
  # @param [Symbol] hook_name The hook to execute
  # @param [Array] args The arguments to pass to the hook.
  def exec_hook(hook_name, *args, &block)
    hooks[hook_name].call(*args, &block) if hooks[hook_name]
  end
  
  # Start a read-eval-print-loop.
  # If no parameter is given, default to top-level (main).
  # @param [Object, Binding] target The receiver of the Pry session
  # @return [Object] The target of the Pry session
  # @example
  #   Pry.new.repl(Object.new)
  def repl(target=TOPLEVEL_BINDING)
    target = binding_for(target)
    target_self = target.eval('self')

    exec_hook :before_session, output, target_self
    
    nesting_level = nesting.size

    Pry.active_instance = self

    # Make sure special locals exist
    target.eval("_pry_ = Pry.active_instance")
    target.eval("_ = Pry.last_result")
    
    break_level = catch(:breakout) do
      nesting << [nesting.size, target_self]
      loop do
        rep(target) 
      end
    end

    nesting.pop
    
    exec_hook :after_session, output, target_self

    # we only enter here if :breakout has been thrown
    if nesting_level != break_level
      throw :breakout, break_level 
    end
    
    target_self
  end
  
  # Perform a read-eval-print.
  # If no parameter is given, default to top-level (main).
  # @param [Object, Binding] target The receiver of the read-eval-print
  # @example
  #   Pry.new.rep(Object.new)
  def rep(target=TOPLEVEL_BINDING)
    target = binding_for(target)
    print.call output, re(target)
  end

  # Perform a read-eval
  # If no parameter is given, default to top-level (main).
  # @param [Object, Binding] target The receiver of the read-eval-print
  # @return [Object] The result of the eval or an `Exception` object in case of error.
  # @example
  #   Pry.new.re(Object.new)
  def re(target=TOPLEVEL_BINDING)
    target = binding_for(target)
    Pry.last_result = target.eval r(target)
    Pry.active_instance = self
    target.eval("_pry_ = Pry.active_instance")
    target.eval("_ = Pry.last_result")
  rescue SystemExit => e
    exit
  rescue Exception => e
    e
  end

  # Perform a read.
  # If no parameter is given, default to top-level (main).
  # This is a multi-line read; so the read continues until a valid
  # Ruby expression is received.
  # Pry commands are also accepted here and operate on the target.
  # @param [Object, Binding] target The receiver of the read.
  # @return [String] The Ruby expression.
  # @example
  #   Pry.new.r(Object.new)
  def r(target=TOPLEVEL_BINDING)
    target = binding_for(target)
    eval_string = ""
    loop do
      val = input.read(prompt(eval_string, target))
      eval_string << "#{val.chomp}\n"
      process_commands(val, eval_string, target)
      
      break eval_string if valid_expression?(eval_string)
    end
  end
  
  # Process Pry commands. Pry commands are not Ruby methods and are evaluated
  # prior to Ruby expressions.
  # Commands can be modified/configured by the user: see `Pry::Commands`
  # This method should not need to be invoked directly - it is called
  # by `Pry#r`
  # @param [String] val The current line of input.
  # @param [String] eval_string The cumulative lines of input for
  #   multi-line input.
  # @param [Object] target The receiver of the commands.
  def process_commands(val, eval_string, target)
    def eval_string.clear() replace("") end

    pattern, action = commands.commands.find { |k, v| Array(k).any? { |a| a === val } }

    if pattern
      options = {
        :captures => $~ ? $~.captures : nil,
        :eval_string => eval_string,
        :target => target,
        :val => val,
        :nesting => nesting,
        :output => output
      }

      action.call(options)
    end
  end

  # Returns the appropriate prompt to use.
  # This method should not need to be invoked directly.
  # @param [String] eval_string The cumulative lines of input for
  #   multi-line input.
  # @param [Object] target The receiver of the Pry session.
  # @return [String] The prompt.
  def prompt(eval_string, target)
    target_self = target.eval('self')
    
    if eval_string.empty?
      default_prompt.first.call(target_self, nesting.level)
    else
      default_prompt.last.call(target_self, nesting.level)
    end
  end

  if RUBY_VERSION =~ /1.9/
    require 'ripper'

    # Determine if a string of code is a valid Ruby expression.
    # Ruby 1.9 uses Ripper, Ruby 1.8 uses RubyParser.
    # @param [String] code The code to validate.
    # @return [Boolean] Whether or not the code is a valid Ruby expression.
    # @example
    #   valid_expression?("class Hello") #=> false
    #   valid_expression?("class Hello; end") #=> true
    def valid_expression?(code)
      !!Ripper::SexpBuilder.new(code).parse
    end
    
  else
    require 'ruby_parser'
    
    # Determine if a string of code is a valid Ruby expression.
    # Ruby 1.9 uses Ripper, Ruby 1.8 uses RubyParser.
    # @param [String] code The code to validate.
    # @return [Boolean] Whether or not the code is a valid Ruby expression.
    # @example
    #   valid_expression?("class Hello") #=> false
    #   valid_expression?("class Hello; end") #=> true
    def valid_expression?(code)
      RubyParser.new.parse(code)
    rescue Racc::ParseError, SyntaxError
      false
    else
      true
    end
  end

  
  # Return a `Binding` object for `target` or return `target` if it is
  # already a `Binding`.
  # In the case where `target` is top-level then return `TOPLEVEL_BINDING`
  # @param [Object] target The object to get a `Binding` object for.
  # @return [Binding] The `Binding` object.
  def binding_for(target)
    if target.is_a?(Binding)
      target
    else
      if target == TOPLEVEL_BINDING.eval('self')
        TOPLEVEL_BINDING
      else
        target.__binding__
      end
    end
  end
end