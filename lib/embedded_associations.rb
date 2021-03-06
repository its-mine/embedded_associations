require "embedded_associations/rails"
require "embedded_associations/version"

module EmbeddedAssociations

  def self.included(base)
    base.instance_eval do

      class_attribute :embedded_associations

      def self.embedded_association(definition)
        unless embedded_associations
          self.embedded_associations = Definitions.new
        end
        self.embedded_associations = embedded_associations.add_definition(definition)
      end
    end
  end

  def handle_embedded_associations(resource, params)
    Processor.new(embedded_associations, self, resource, params).run
  end

  def filter_attributes(name, attrs, action)
    attrs
  end

  # Simple callbacks for now, eventually should use a filter system
  def before_embedded(record, action); end

  class Definitions
    include Enumerable

    attr_accessor :definitions

    def initialize
      @definitions = []
    end

    # Keep immutable to prevent all controllers
    # from sharing the same copy
    def add_definition(definition)
      result = self.dup
      result.definitions << definition
      result
    end

    def initialize_copy(source)
      self.definitions = source.definitions.dup
    end

    def each(&block)
      self.definitions.each &block
    end
  end

  class Processor

    attr_reader :definitions
    attr_reader :controller
    attr_reader :resource
    attr_reader :params

    def initialize(definitions, controller, resource, params)
      @definitions = definitions
      @controller = controller
      @params = params
      @resource = resource
    end

    def run
      definitions.each do |definition|
        handle_resource(definition, resource, params)
      end
    end

    private

    # Definition can be either a name, array, or hash.
    def handle_resource(definition, parent, parent_params)
      if definition.is_a? Array
        return definition.each{|d| handle_resource(d, parent, parent_params)}
      end
      # normalize to a hash
      unless definition.is_a? Hash
        definition = {definition => nil}
      end

      definition.each do |name, child_definition|
        if !parent_params || !parent_params.has_key?(name.to_s)
          next
        end
        
        reflection = parent.class.reflect_on_association(name)
        
        attrs = parent_params.delete(name.to_s)

        if reflection.collection?
          attrs ||= []
          handle_plural_resource parent, name, attrs, child_definition
        else
          handle_singular_resource parent, name, attrs, child_definition
        end
      end
    end

    def handle_plural_resource(parent, name, attr_array, child_definition)
      current_assoc = parent.send(name)

      # Mark non-existant records as deleted
      current_assoc.select{|r| attr_array.none?{|attrs| attrs['id'] && attrs['id'].to_i == r.id}}.each do |r|
        handle_resource(child_definition, r, nil) if child_definition
        run_before_destroy_callbacks(r)
        r.mark_for_destruction
      end

      attr_array.each do |attrs|
        if id = attrs['id']
          # can't use current_assoc.find(id), see http://stackoverflow.com/questions/11605120/autosave-ignored-on-has-many-relation-what-am-i-missing
          r = current_assoc.find{|r| r.id == id.to_i}
          attrs = controller.send(:filter_attributes, r.class.name, attrs, :update)
          handle_resource(child_definition, r, attrs) if child_definition
          r.assign_attributes(attrs)
          run_before_update_callbacks(r)
        else
          inheritance_column = parent.class.reflect_on_association(name).klass.inheritance_column
          # need to pass in inheritance column in build to get correct class
          r = if inheritance_column
            current_assoc.build(attrs.slice(inheritance_column))
          else
            current_assoc.build()
          end
          attrs = controller.send(:filter_attributes, r.class.name, attrs, :create)
          handle_resource(child_definition, r, attrs) if child_definition
          r.assign_attributes(attrs)
          run_before_create_callbacks(r)
        end
      end
    end

    def handle_singular_resource(parent, name, attrs, child_definition)
      current_assoc = parent.send(name)

      if r = current_assoc
        if attrs && attrs != ''
          attrs = controller.send(:filter_attributes, r.class.name, attrs, :update)
          handle_resource(child_definition, r, attrs) if child_definition
          r.assign_attributes(attrs)
          run_before_update_callbacks(r)
        else
          handle_resource(child_definition, r, attrs) if child_definition
          run_before_destroy_callbacks(r)
          r.mark_for_destruction
        end
      elsif attrs && attrs != ''
        inheritance_column = parent.class.reflect_on_association(name).klass.inheritance_column
        # need to pass in inheritance column in build to get correct class
        r = if inheritance_column
          parent.send("build_#{name}", attrs.slice(inheritance_column))
        else
          parent.send("build_#{name}")
        end
        attrs = controller.send(:filter_attributes, r.class.name, attrs, :create)
        handle_resource(child_definition, r, attrs) if child_definition
        r.assign_attributes(attrs)
        run_before_create_callbacks(r)
      end
    end

    def run_before_create_callbacks(record)
      controller.send(:before_embedded, record, :create)
    end

    def run_before_update_callbacks(record)
      controller.send(:before_embedded, record, :update)
    end

    def run_before_destroy_callbacks(record)
      controller.send(:before_embedded, record, :destroy)
    end
  end

end
