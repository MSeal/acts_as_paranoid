module ActsAsParanoid
  module Core
    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods
      def self.extended(base)
        base.define_callbacks :recover, terminator: lambda { |target, result| result == false }
        base.define_callbacks :soft_destroy, terminator: lambda { |target, result| result == false }
      end

      def before_recover(method)
        set_callback :recover, :before, method
      end

      def after_recover(method)
        set_callback :recover, :after, method
      end

      def before_soft_destroy(method)
        set_callback :soft_destroy, :before, method
      end

      def after_soft_destroy(method)
        set_callback :soft_destroy, :after, method
      end

      def with_deleted
        without_paranoid_default_scope
      end

      def only_deleted
        if string_type_with_deleted_value?
          without_paranoid_default_scope.where("#{paranoid_column_reference} IS ?", paranoid_configuration[:deleted_value])
        else
          without_paranoid_default_scope.where("#{paranoid_column_reference} IS NOT ?", nil)
        end
      end

      def delete_all!(conditions = nil)
        without_paranoid_default_scope.delete_all!(conditions)
      end

      def delete_all(conditions = nil)
        where(conditions).update_all(["#{paranoid_configuration[:column]} = ?", delete_now_value])
      end

      def paranoid_default_scope_sql
        if string_type_with_deleted_value?
          self.all.table[paranoid_column].eq(nil).
              or(self.all.table[paranoid_column].not_eq(paranoid_configuration[:deleted_value])).
              to_sql
        else
          self.all.table[paranoid_column].eq(nil).to_sql
        end
      end

      def string_type_with_deleted_value?
        paranoid_column_type == :string && !paranoid_configuration[:deleted_value].nil?
      end

      def paranoid_column
        paranoid_configuration[:column].to_sym
      end

      def paranoid_column_type
        paranoid_configuration[:column_type].to_sym
      end

      def dependent_associations
        self.reflect_on_all_associations.select { |a| [:destroy, :delete_all].include?(a.options[:dependent]) }
      end

      def delete_now_value
        case paranoid_configuration[:column_type]
          when "time"
            Time.now
          when "boolean"
            true
          when "string"
            paranoid_configuration[:deleted_value]
        end
      end

      protected

      def without_paranoid_default_scope
        scope = self.all
        if scope.where_values.include? paranoid_default_scope_sql
          # ActiveRecord 4.1
          scope.where_values.delete(paranoid_default_scope_sql)
        else
          scope = scope.with_default_scope
          scope.where_values.delete(paranoid_default_scope_sql)
        end

        scope
      end
    end

    def persisted?
      !(new_record? || @destroyed)
    end

    def paranoid_value
      self.send(self.class.paranoid_column)
    end

    def destroy_fully!
      with_transaction_returning_status do
        destroy_dependent_associations!
        run_callbacks :destroy do
          # Handle composite keys, otherwise we would just use `self.class.primary_key.to_sym => self.id`.
          self.class.delete_all!(Hash[[Array(self.class.primary_key), Array(self.id)].transpose]) if persisted?
          self.paranoid_value = self.class.delete_now_value
          freeze
        end
      end
    end

    def destroy!
      unless deleted?
        with_transaction_returning_status do
          if self.class.paranoid_configuration[:dependent_destroy_paranoid_only]
            run_callbacks :soft_destroy do
              destroy_paranoid_associations
              self.paranoid_value = self.class.delete_now_value
              self.save!
            end
          else
            run_callbacks :destroy do
              # Handle composite keys, otherwise we would just use `self.class.primary_key.to_sym => self.id`.
              self.class.delete_all(Hash[[Array(self.class.primary_key), Array(self.id)].transpose]) if persisted?
              self.paranoid_value = self.class.delete_now_value
              self
            end
          end
        end
      else
        destroy_fully!
      end
    end

    def destroy
      destroy!
    end

    def recover(options={})
      options = {
          :recursive => self.class.paranoid_configuration[:recover_dependent_associations],
          :recovery_window => self.class.paranoid_configuration[:dependent_recovery_window]
      }.merge(options)

      self.class.transaction do
        run_callbacks :recover do
          paranoid_original_value = self.paranoid_value
          self.paranoid_value = nil
          self.save!

          recover_dependent_associations(paranoid_original_value, options[:recovery_window], options) if options[:recursive]
        end
      end
    end

    def recover_dependent_associations(paranoid_original_value, window, options)
      self.class.dependent_associations.each do |reflection|
        next unless (klass = get_reflection_class(reflection)).paranoid?

        scope = klass.only_deleted

        # Merge in the association's scope
        scope = scope.merge(association(reflection.name).association_scope)

        # We can only recover by window if both parent and dependant have a
        # paranoid column type of :time.
        if self.class.paranoid_column_type == :time && klass.paranoid_column_type == :time
          scope = scope.deleted_inside_time_window(paranoid_original_value, window)
        end

        unless reflection.options[:dependent] == :delete_all
          scope.each do |object|
            object.recover(options)
          end
        else
          scope.update_all(self.class.paranoid_column => nil)
        end
      end
    end

    def destroy_dependent_associations!
      self.class.dependent_associations.each do |reflection|
        next unless (klass = get_reflection_class(reflection)).paranoid?

        # Merge in the association's scope
        scope = association(reflection.name).association_scope

        scope.each do |object|
          object.destroy_fully!
        end
      end
    end

    def destroy_paranoid_associations
      self.class.dependent_associations.each do |reflection|
        if reflection.klass.paranoid?
          dependent_type = reflection.options[:dependent]
          association_scope = association(reflection.name).association_scope.where(self.class.paranoid_column => nil)
          if dependent_type == :destroy
            association_scope.each do |object|
              object.send(reflection.options[:dependent])
            end
          elsif dependent_type == :delete_all
            association_scope.delete_all
          end
        end
      end
    end

    def deleted?
      !(paranoid_value.nil? ||
          (self.class.string_type_with_deleted_value? && paranoid_value != self.class.delete_now_value))
    end

    alias_method :destroyed?, :deleted?

    private

    def get_reflection_class(reflection)
      if reflection.macro == :belongs_to && reflection.options.include?(:polymorphic)
        self.send(reflection.foreign_type).constantize
      else
        reflection.klass
      end
    end

    def paranoid_value=(value)
      self.send("#{self.class.paranoid_column}=", value)
    end
  end
end
