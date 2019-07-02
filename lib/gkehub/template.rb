# frozen_string_literal: true

require 'erb'

module GKE
  # Tamplate is a collection of erb template
  module Template
    # Render is a class for templating
    class Render
      attr_accessor :context

      def initialize(context)
        @context = context
      end

      def render(template)
        ERB.new(template).result(get_binding)
      end

      # rubocop:disable Naming/AccessorMethodName
      def get_binding
        binding
      end
      # rubocop:enable Naming/AccessorMethodName
    end
  end
end
