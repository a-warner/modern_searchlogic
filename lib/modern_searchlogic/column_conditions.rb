module ModernSearchlogic
  module ColumnConditions
    module ClassMethods
      def respond_to_missing?(method, *)
        super || !!searchlogic_column_condition_method_block(method.to_s)
      end

      private

      def searchlogic_suffix_condition(suffix, options = {}, &method_block)
        searchlogic_suffix_conditions[suffix] = [options, method_block]
      end

      def searchlogic_column_prefix(prefix, &method_block)
        searchlogic_column_prefixes[prefix] = method_block
      end

      def searchlogic_arel_alias(searchlogic_suffix, arel_method, options = {})
        value_mapper = options.fetch(:map_value, ->(x) { x })

        searchlogic_suffix_condition "_#{searchlogic_suffix}", options do |column_name, *args|
          values = coerce_and_validate_args_for_arel_aliases!(args, options)
          arel_table[column_name].__send__(arel_method, value_mapper.call(values))
        end

        searchlogic_suffix_condition "_#{searchlogic_suffix}_any", options do |column_name, *args|
          values = coerce_and_validate_args_for_arel_aliases!(args, options.merge(:any_or_all => true))
          arel_table[column_name].__send__("#{arel_method}_any", values.map(&value_mapper))
        end

        searchlogic_suffix_condition "_#{searchlogic_suffix}_all", options do |column_name, *args|
          values = coerce_and_validate_args_for_arel_aliases!(args, options.merge(:any_or_all => true))
          arel_table[column_name].__send__("#{arel_method}_all", values.map(&value_mapper))
        end
      end

      def searchlogic_suffix_condition_match(method_name)
        suffix_regexp = searchlogic_suffix_conditions.keys.join('|')
        if match = method_name.match(/\A(#{column_names_regexp}(?:_or_#{column_names_regexp})*)(#{suffix_regexp})\z/)
          options, method_block = searchlogic_suffix_conditions.fetch(match[2])
          column_names = match[1].split('_or_')

          return lambda do |*args|
            if options[:expecting_args] && args.length != options[:expecting_args]
              raise ArgumentError, "wrong number of arguments (#{args.length} for #{options[:expecting_args]})"
            end

            arel_conditions = column_names.map { |n| instance_exec(n, *args, &method_block) }.reduce(:or)
            where(arel_conditions)
          end
        end
      end

      def searchlogic_prefix_match(method_name)
        prefix_regexp = searchlogic_column_prefixes.keys.join('|')
        if match = method_name.match(/\A(#{prefix_regexp})(#{column_names_regexp})\z/)
          method_block = searchlogic_column_prefixes.fetch(match[1])
          return lambda { |*args| instance_exec(match[2], *args, &method_block) }
        elsif match = method_name.match(/\A(#{prefix_regexp})(#{association_names_regexp})_(\S+)\z/)
          prefix, association_name, rest = match.to_a.drop(1)
          association = association_by_name.fetch(association_name.to_sym)
          association_finder = prefix + rest

          if association.klass.respond_to?(association_finder)
            return lambda do |*args|
              scope = association.klass.__send__(association_finder, *args)
              unless ActiveRecord::Relation === scope
                raise ArgumentError, "Expected #{association_finder.inspect} to return an ActiveRecord::Relation"
              end

              joins(association.name).merge(scope)
            end
          end
        end
      end

      def searchlogic_association_finder_match(method_name)
        reflect_on_all_associations.each do |a|
          if method_name =~ /\A#{a.name}_(\S+)\z/ && a.klass.respond_to?($1)
            association_scope_name = $1
            return lambda do |*args|
              scope = a.klass.__send__(association_scope_name, *args)
              unless ActiveRecord::Relation === scope
                raise ArgumentError, "Expected #{association_scope_name.inspect} to return an ActiveRecord::Relation"
              end

              joins(a.name).merge(scope)
            end
          end
        end

        nil
      end

      def association_by_name
        reflect_on_all_associations.each.with_object({}) do |assoc, obj|
          obj[assoc.name] = assoc
        end
      end

      def association_names_regexp
        association_by_name.keys.join('|')
      end

      def searchlogic_column_condition_method_block(method)
        method = method.to_s
        searchlogic_prefix_match(method) ||
          searchlogic_suffix_condition_match(method) ||
          searchlogic_association_finder_match(method)
      end

      def column_names_regexp
        "(?:#{column_names.join('|')})"
      end

      def method_missing(method, *args, &block)
        return super unless method_block = searchlogic_column_condition_method_block(method.to_s)

        singleton_class.__send__(:define_method, method, &method_block)

        __send__(method, *args, &block)
      end

      def coerce_and_validate_args_for_arel_aliases!(args, options)
        any_or_all = options[:any_or_all]

        if options[:takes_array_args]
          args = [any_or_all ? args : args.flatten]
        elsif any_or_all
          args = [args.flatten]
        end

        if any_or_all
          raise ArgumentError, "wrong number of arguments (0 for >= 1)" if args.first.length.zero?
        elsif args.length != 1
          raise ArgumentError, "wrong number of arguments (#{args.length} for 1)"
        end

        args.first
      end
    end

    def self.included(base)
      base.extend ClassMethods

      base.class_eval do
        class_attribute :searchlogic_suffix_conditions
        self.searchlogic_suffix_conditions = {}

        class_attribute :searchlogic_column_prefixes
        self.searchlogic_column_prefixes = {}

        searchlogic_arel_alias :equals, :eq
        searchlogic_arel_alias :eq, :eq
        searchlogic_arel_alias :is, :eq
        searchlogic_arel_alias :does_not_equal, :not_eq
        searchlogic_arel_alias :ne, :not_eq
        searchlogic_arel_alias :not_eq, :not_eq
        searchlogic_arel_alias :greater_than, :gt
        searchlogic_arel_alias :gt, :gt
        searchlogic_arel_alias :less_than, :lt
        searchlogic_arel_alias :lt, :lt
        searchlogic_arel_alias :greater_than_or_equal_to, :gteq
        searchlogic_arel_alias :gte, :gteq
        searchlogic_arel_alias :less_than_or_equal_to, :lteq
        searchlogic_arel_alias :lte, :lteq
        searchlogic_arel_alias :in, :in, :takes_array_args => true
        searchlogic_arel_alias :not_in, :not_in, :takes_array_args => true
        searchlogic_arel_alias :like, :matches, :map_value => -> (val) { "%#{val}%" }
        searchlogic_arel_alias :begins_with, :matches, :map_value => -> (val) { "#{val}%" }
        searchlogic_arel_alias :ends_with, :matches, :map_value => -> (val) { "%#{val}" }
        searchlogic_arel_alias :not_like, :does_not_match, :map_value => -> (val) { "%#{val}%" }
        searchlogic_arel_alias :not_begin_with, :does_not_match, :map_value => -> (val) { "#{val}%" }
        searchlogic_arel_alias :not_end_with, :does_not_match, :map_value => -> (val) { "%#{val}" }

        searchlogic_suffix_condition '_blank', :expecting_args => 0 do |column_name|
          arel_table[column_name].eq(nil).or(arel_table[column_name].eq(''))
        end

        searchlogic_suffix_condition '_present', :expecting_args => 0 do |column_name|
          arel_table[column_name].not_eq(nil).and(arel_table[column_name].not_eq(''))
        end

        null_matcher = lambda { |column_name| arel_table[column_name].eq(nil) }
        searchlogic_suffix_condition '_null', :expecting_args => 0, &null_matcher
        searchlogic_suffix_condition '_nil', :expecting_args => 0, &null_matcher

        not_null_matcher = lambda { |column_name| arel_table[column_name].not_eq(nil) }
        searchlogic_suffix_condition '_not_null', :expecting_args => 0, &not_null_matcher
        searchlogic_suffix_condition '_not_nil', :expecting_args => 0, &not_null_matcher

        searchlogic_column_prefix 'descend_by_' do |column_name|
          order(column_name => :desc)
        end

        searchlogic_column_prefix 'ascend_by_' do |column_name|
          order(column_name => :asc)
        end
      end
    end
  end
end
