# frozen_string_literal: true

module Experiments
  class CopyExperimentAsTemplateService
    extend Service

    attr_reader :errors, :c_exp
    alias cloned_experiment c_exp

    def initialize(experiment_id:, project_id:, user_id:)
      @exp = Experiment.find experiment_id
      @project = Project.find project_id
      @user = User.find user_id
      @original_project = @exp&.project
      @c_exp = nil
      @errors = {}
    end

    def call
      return self unless valid?

      ActiveRecord::Base.transaction do
        @c_exp = Experiment.new(
          name: find_uniq_name,
          description: @exp.description,
          created_by: @user,
          last_modified_by: @user,
          project: @project
        )

        # Copy all signle taskas
        @c_exp.my_modules << @exp.my_modules.without_group.map do |m|
          m.deep_clone_to_experiment(@user, @c_exp)
        end

        # Copy all grouped tasks
        @exp.my_module_groups.each do |g|
          @c_exp.my_module_groups << g.deep_clone_to_experiment(@user, @c_exp)
        end

        raise ActiveRecord::Rollback unless @c_exp.save
      end
      @errors.merge!(@c_exp.errors.to_hash) unless @c_exp.valid?

      @c_exp = nil unless succeed?
      @c_exp.delay.generate_workflow_img if succeed?
      track_activity if succeed?

      self
    end

    def succeed?
      @errors.none?
    end

    private

    def find_uniq_name
      experiment_names = @project.experiments.map(&:name)
      format = 'Clone %d - %s'
      free_index = 1
      free_index += 1 while experiment_names
                            .include?(format(format, free_index, @exp.name))
      format(format, free_index, @exp.name).truncate(Constants::NAME_MAX_LENGTH)
    end

    def valid?
      unless @exp && @project && @user
        @errors[:invalid_arguments] =
          { 'experiment': @exp,
            'project': @project,
            'user': @user }
          .map do |key, value|
            "Can't find #{key.capitalize}" if value.nil?
          end.compact
        return false
      end

      if @exp.projects_with_role_above_user(@user).include?(@project)
        true
      else
        @errors[:user_without_permissions] =
          ['You are not allowed to copy this experiment to this project']
        false
      end
    end

    def track_activity
      Activity.create(
        type_of: :clone_experiment,
        project: @project,
        experiment: @exp,
        user: @user,
        message: I18n.t(
          'activities.clone_experiment',
          user: @user.full_name,
          experiment_new: @c_exp.name,
          experiment_original: @exp.name
        )
      )
    end
  end
end
