module ModernSearchlogic
  module ScopeTracking
    module ClassMethods
      def scope(name, body, &block)
        super(name, body, &block).tap do |*|
          _defined_scopes << name.to_sym
        end
      end
    end

    def self.included(base)
      base.extend ClassMethods
      base.class_eval do
        class_attribute :_defined_scopes
        self._defined_scopes = Set.new
      end
    end
  end
end
