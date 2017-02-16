module JavaUtilities

  class Parameter
    attr_reader :type

    def initialize(a_type)
      @type = a_type
    end

    def primitive_of?(a)
      false
    end

    def can_accept?(a)
      if a.kind_of?(JavaProxy)
        begin
          return Java.invoke_java_method(
                   JavaUtilities::JavaDispatcher::CLASS_IS_ASSIGNABLE_FROM, @type,
                   JavaUtilities.unwrap_java_value(a.class.java_class))
        rescue java.lang.ClassCastException => e
          p "Called with #{@type} and #{a.class.java_class}, and failed."
          raise e
        end
      end
    end

    def box_of?(a)
      false
    end

    def can_accept_duck_type?(a)
      false
    end

    def fast_checker(a)
      a_class = a.class
      lambda { |x| x.class == a_class }
    end

    def <=>(another)
      return 0 if Java.java_refs_equal?(@type, another.type)
      return -1 if Java.invoke_java_method(
                     JavaUtilities::JavaDispatcher::CLASS_IS_ASSIGNABLE_FROM, @type,
                     another.type)
      return 1 if Java.invoke_java_method(
                     JavaUtilities::JavaDispatcher::CLASS_IS_ASSIGNABLE_FROM, another.type,
                     @type)
      return 0
    end

    ParameterCache = ClassCache.new

    def self.for_type( a_type )
      cached = ParameterCache[a_type]
      return cached unless cached == nil
      cached = Parameter.new(a_type)
      race_cached = ParameterCache.put_if_absent(a_type, cached)
      return cached unless race_cached
      race_cached
    end
  end

  class IntegerParameter < Parameter
    attr_reader :range
    attr_reader :checker

    def initialize( range, type )
      @range = range
      @checker = lambda { |x| x.class == Fixnum && range.include?(x) }
      super(type)
    end

    def can_accept?(a)
      in_range?(a) rescue false
    end

    def in_range?(a)
      range.include?(a)
    end

    def fast_checker(a)
      return checker
    end
  end

  class PrimitiveIntegerParameter < IntegerParameter
    def primitive_of?(a)
      a.class == Fixnum && in_range?(a)
    end
  end

  class BoxedIntegerParameter < IntegerParameter
    def box_of?(a)
      a.class == Fixnum && in_range?(a)
    end
  end

  class FloatParameter < Parameter
    attr_reader :boxed

    def initialize( is_boxed, type )
      @boxed = is_boxed
      super(type)
    end

    def primitive_of?(a)
      a.class == Float && !@boxed
    end

    def box_of?(a)
      a.class == Float && @boxed
    end

    def can_accept?(a)
      a.class == Float
    end
  end

  class BooleanParameter < Parameter
    attr_reader :boxed

    def initialize( is_boxed, type )
      @boxed = is_boxed
      super(type)
    end

    def primitive_of?(a)
      !@boxed
    end

    def box_of?(a)
      @boxed
    end
  end

  class StringParameter < Parameter
    def initialize(type)
      super(type)
    end

    def can_accept?(a)
      a.class == String || a.class == Symbol
    end
  end

  # We'll want to populate the common primitive and boxed types
  begin
    integer_types = { "java.lang.Byte" => -2**7...2**7,
                      "java.lang.Character" => 0...2**16,
                      "java.lang.Short" => -2**15...2**15,
                      "java.lang.Integer" => -2**31...2**31,
                      "java.lang.Long" => -2**63...2**63 }
    integer_types.each do |t|
      java_type = Java.java_class_by_name(t[0])
      prim_type = Java.invoke_java_method(
        FIELD_GET, Java.invoke_java_method(
          CLASS_GET_FIELD, java_type, Java.to_java_string("TYPE")),
        nil)
      boxed_param = BoxedIntegerParameter.new(t[1], java_type)
      prim_param = PrimitiveIntegerParameter.new(t[1], prim_type)
      Parameter::ParameterCache.put_if_absent(java_type, boxed_param)
      Parameter::ParameterCache.put_if_absent(prim_type, prim_param)
    end

    float_types = ["java.lang.Float", "java.lang.Double"]

    float_types.each do |t|
      java_type = Java.java_class_by_name(t)
      prim_type = Java.invoke_java_method(
        FIELD_GET, Java.invoke_java_method(
          CLASS_GET_FIELD, java_type, Java.to_java_string("TYPE")),
        nil)
      boxed_param = FloatParameter.new(true, java_type)
      prim_param = FloatParameter.new(false, prim_type)
      Parameter::ParameterCache.put_if_absent(java_type, boxed_param)
      Parameter::ParameterCache.put_if_absent(prim_type, prim_param)
    end

    java_type = Java.java_class_by_name("java.lang.Boolean")
    prim_type = Java.invoke_java_method(
      FIELD_GET, Java.invoke_java_method(
        CLASS_GET_FIELD, java_type, Java.to_java_string("TYPE")),
      nil)
    boxed_param = BooleanParameter.new(true, java_type)
    prim_param = BooleanParameter.new(false, prim_type)
    Parameter::ParameterCache.put_if_absent(java_type, boxed_param)
    Parameter::ParameterCache.put_if_absent(prim_type, prim_param)

    java_type = Java.java_class_by_name("java.lang.String")
    param = StringParameter.new(java_type)
    Parameter::ParameterCache.put_if_absent(java_type, param)

  end

  class Callable
    attr_reader :mh
    attr_reader :params

    class Parameters
      def initialize( params, var_args)
        @params = params.map { |t| Parameter.for_type(t) }
        @var_args
      end

      def [](index)
        if ! @var_args || index < @params.size - 1
          @params[index]
        else
          @params.last
        end
      end
    end

    def initialize(mh)
      @mh = mh
      @params = Parameters.new(JavaDispatcher.method_types(mh),
                               JavaDispatcher.method_is_varargs(mh))
    end

    def more_specific(another, args)
      comp = 0
      (0...args.size).each { |i| comp += params[i] <=> another.params[i] }
      if comp > 0
        another
      else
        self
      end
    end
  end

  class CallableSelector
    attr_reader :callables

    def initialize(methods)
      @callables = methods.map { |m| Callable.new(m) }
    end

    def find_callable_candidates(
          args)  # list of arguments
      methods = self.callables
      retained = methods # Need to handle the case where there are no arguments.
      (0...args.size).each do |i|
        retained = []
        a = args[i]
        methods.each do |c|
          p = c.params[i]
          if p.primitive_of?(a) || # arg can be unboxed.
             p.can_accept?(a) # arg can be boxed or is subclass of t
            retained << c
          end
        end
        if retained.empty?
          methods.each do |c|
            p = c.parame[i]
            if p.can_accept_duck_type?(a) # p is na interface, t is not a subtype of p, and t is a ruby object.
              retained << c
            end
          end
        end
        methods = retained
      end
      return retained
    end

    def find_matching_callable_for_args( args )
      candidates = find_callable_candidates( args )
      case candidates.size
      when 0
        raise TypeError, "No java method found that accepts #{args}."
      # Try via some other way
      when 1
        return candidates[0].mh
      else
        # raise TypeError, "Can't dispatch ambiguous cases yet."
        return narrow_to_specific_callable( candidates, args)
      end
    end

    def narrow_to_specific_callable( candidates, args )
      # Start with just handling more specific  types.
      c = candidates.first
      candidates.each { |x| c = c.more_specific(x, args) }
      c
    end
  end
end
