Proc.new do |
	clusterName: nil # name of the ECS Cluster to attach to
|
	{
		"commands" => {
			"00_configure_sweep" => {
				"test" => interpolate(<<-END_SH.gsub(/^\s+/, "")
					#!/bin/bash -xe
					cfg='ECS_ENGINE_TASK_CLEANUP_WAIT_DURATION=5m'
					if [[ -e /etc/ecs/ecs.config ]] && grep -q -F "$cfg" /etc/ecs/ecs.config; then
						false
					else
						true
					fi
				END_SH
				),
				"command" => interpolate(<<-END_SH.gsub(/^\s+/, "")
					#!/bin/bash -xe
					cfg='ECS_ENGINE_TASK_CLEANUP_WAIT_DURATION=5m'
					mkdir -p /etc/ecs
					echo "$cfg" >> /etc/ecs/ecs.config
				END_SH
				)
			},
			"50_add_instance_to_cluster" => {
				"test" => interpolate(<<-END_SH.gsub(/^\s+/, ""), {cn: clusterName}
					#!/bin/bash -xe,
					cfg='ECS_CLUSTER={{ locals[:cn] }}'
					if [[ -e /etc/ecs/ecs.config ]] && grep -q -F "$cfg" /etc/ecs/ecs.config; then
						false
					else
						true
					fi
				END_SH
				),
				"command" => interpolate(<<-END_SH.gsub(/^\s+/, ""), {cn: clusterName}
					#!/bin/bash -xe
					cfg='ECS_CLUSTER={{ locals[:cn] }}'
					mkdir -p /etc/ecs
					echo "$cfg" >> /etc/ecs/ecs.config
				END_SH
				)
			}
		}
	}
end
