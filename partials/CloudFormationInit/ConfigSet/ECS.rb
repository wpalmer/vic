Proc.new do |
	clusterName: nil, # name of the ECS Cluster to attach to
	storageDriver: nil # the docker storage driver to use
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
			"10_configure_log_drivers" => {
				"test" => interpolate(<<-END_SH.gsub(/^\s+/, "")
					#!/bin/bash -xe
					cfg='ECS_AVAILABLE_LOGGING_DRIVERS=["json-file","awslogs","gelf"]'
					if [[ -e /etc/ecs/ecs.config ]] && grep -q -F "$cfg" /etc/ecs/ecs.config; then
						false
					else
						true
					fi
				END_SH
				),
				"command" => interpolate(<<-END_SH.gsub(/^\s+/, "")
					#!/bin/bash -xe
					cfg='ECS_AVAILABLE_LOGGING_DRIVERS=["json-file","awslogs","gelf"]'
					mkdir -p /etc/ecs
					echo "$cfg" >> /etc/ecs/ecs.config
				END_SH
				)
			},
			"20_configure_storage_driver" => {
				"test" =>
					if storageDriver.nil?
						"#!/bin/bash -xe\n# no storageDriver specified\nexit 1\n"
					else
						interpolate(<<-END_SH.gsub(/^\s+/, ""), {driver: storageDriver}
							#!/bin/bash -xe
							cfg='DOCKER_STORAGE_OPTIONS="--storage-driver {{locals[:driver]}}"'
							if [[ -e /etc/sysconfig/docker-storage ]] && grep -q -F "$cfg" /etc/sysconfig/docker-storage; then
								false
							else
								true
							fi
							END_SH
						)
					end,
				"command" =>
					if storageDriver.nil?
						"#!/bin/bash -xe\n# no storageDriver specified\nexit 1\n"
					elsif storageDriver == "overlay2"
						interpolate(<<-END_SH.gsub(/^\s+/, "")
							#!/bin/bash -xe
							pool=/dev/docker/docker-pool
							target=/var/lib/docker/overlay2

							## Stop Docker before we mess with it
							service docker stop

							## Ensure Device is Mounted
							mkdir -p ${target}
							grep -q ${target} /etc/fstab ||
							printf '%s %s ext4 defaults 0 0\\n' \\
								"${pool}" \\
								"${target}" \\
								>> /etc/fstab

							if ! grep -q ${target} /etc/mtab; then
								if ! mount ${pool} 2>&-; then
									# Mounting failed, assume this is due to wrong format
									mkfs -t ext4 ${pool}
									mount ${pool}
								fi
							fi

							## Use overlay2 for Storage
							cfg='DOCKER_STORAGE_OPTIONS="--storage-driver overlay2"'
							echo "$cfg" > /etc/sysconfig/docker-storage

							service docker start
							END_SH
						)
					else
						interpolate(<<-END_SH.gsub(/^\s+/, ""), {driver: storageDriver}
							#!/bin/bash -xe
							cfg='DOCKER_STORAGE_OPTIONS="--storage-driver {{locals[:driver]}}"'
							echo "$cfg" > /etc/sysconfig/docker-storage
							END_SH
						)
					end
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
		},
		"packages" => {
			"yum" => (
				if storageDriver == "overlay2"
					{"parted" => []}
				else
					{ }
				end
			)
		}
	}
end
