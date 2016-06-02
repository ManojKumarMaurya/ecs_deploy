module EcsDeploy
  class TaskDefinition
    def initialize(
      handler:, task_definition_name:, regions: [],
      volumes: [], container_definitions:
    )
      @handler = handler
      @task_definition_name = task_definition_name
      @regions = regions

      @container_definitions = container_definitions.map do |cd|
        if cd[:docker_labels]
          cd[:docker_labels] = cd[:docker_labels].map { |k, v| [k.to_s, v] }.to_h
        end
        if cd[:log_configuration] && cd[:log_configuration][:options]
          cd[:log_configuration][:options] = cd[:log_configuration][:options].map { |k, v| [k.to_s, v] }.to_h
        end
        cd
      end
      @volumes = volumes
    end

    def register
      @handler.clients.each do |region, client|
        next if !@regions.empty? && !@regions.include?(region)

        client.register_task_definition({
          family: @task_definition_name,
          container_definitions: @container_definitions,
          volumes: @volumes,
        })
        EcsDeploy.logger.info "register task definition [#{@task_definition_name}] [#{region}] [#{Paint['OK', :green]}]"
      end
    end

    def run(info)
      regions = info[:regions] || []
      @handler.clients.each do |region, client|
        next if !regions.empty? && !regions.include?(region)

        resp = client.run_task({
          cluster: info[:cluster],
          task_definition: @task_definition_name,
          overrides: {
            container_overrides: info[:container_overrides] || []
          },
          count: info[:count] || 1,
          started_by: "capistrano",
        })
        unless resp.failures.empty?
          resp.failures.each do |f|
            raise "#{f.arn}: #{f.reason}"
          end
        end

        wait_targets = Array(info[:wait_stop])
        unless wait_targets.empty?
          client.wait_until(:tasks_running, cluster: info[:cluster], tasks: resp.tasks.map { |t| t.task_arn })
          client.wait_until(:tasks_stopped, cluster: info[:cluster], tasks: resp.tasks.map { |t| t.task_arn })

          resp = client.describe_tasks(cluster: info[:cluster], tasks: resp.tasks.map { |t| t.task_arn })
          resp.tasks.each do |t|
            t.containers.each do |c|
              next unless wait_targets.include?(c.name)

              unless c.exit_code.zero?
                raise "Task has errors: #{c.reason}"
              end
            end
          end
        end

        EcsDeploy.logger.info "run task [#{@task_definition_name} #{info.inspect}] [#{region}] [#{Paint['OK', :green]}]"
      end
    end
  end
end