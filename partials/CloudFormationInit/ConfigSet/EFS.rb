Proc.new do |
	filesystems: [], # [{id: "anEFSFilesystemId", path: "targetHostPath"}]
	doDockerRestart: false, # whether or not to restart the docker service
	doECSRestart: false # whether or not to restart the ECS service
|
	{
		"commands" => {
			"01_mount_persistent_data" => {
				"test" => interpolate(<<-END_SH.gsub(/^\s+/, ""), {fs: filesystems}
					#!/bin/bash -xe
					EFS_FILESYSTEM_IDS=( {{join(" ", *locals[:fs].map{|fs| fs[:id]})}} )
					PLACEMENT_AZ="$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)"

					for efsid in "${EFS_FILESYSTEM_IDS[@]}"; do
						target="${PLACEMENT_AZ}.${efsid}.efs.{{ref('AWS::Region')}}.amazonaws.com:/"
						if \\
							grep -q $target /etc/fstab &&
							grep -q $target /etc/mtab
						then
							continue
						else
							exit 0
						fi
					done
					exit 1
				END_SH
				),
				"command" => interpolate(<<-END_SH.gsub(/^\s+/, ""), {fs: filesystems}
					#!/bin/bash -xe
					EFS_FILESYSTEM_IDS=( {{join(" ", *locals[:fs].map{|fs| join(":", *[ fs[:id], fs[:path] ])})}} )
					PLACEMENT_AZ="$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)"

					mounts=0
					for efs in "${EFS_FILESYSTEM_IDS[@]}"; do
						efsid="${efs%%:*}"
						efspath="${efs#*:}"
						target="${PLACEMENT_AZ}.${efsid}.efs.{{ref('AWS::Region')}}.amazonaws.com:/"
						mkdir -p ${efspath}
						grep -q $target /etc/fstab ||
							printf '%s %s nfs defaults,vers=4.1 0 0\\n' \\
								"${target}" \\
								"${efspath}" \\
								>> /etc/fstab

						if ! grep -q $target /etc/mtab; then
							mount ${efspath}
							mounts=$(( $mount + 1 ))
						fi
					done

					#{
						if doDockerRestart
							"if [[ $mounts -gt 0 ]]; then service docker restart; fi"
						end
					}
					#{
						if doECSRestart
							"if [[ $mounts -gt 0 ]] && [[ -s /etc/ecs/ecs.config ]]; then start ecs; fi"
						end
					}
				END_SH
				)
			}
		},
		"packages" => {
			"yum" => {
				"jq" => [],
				"nfs-utils" => []
			}
		}
	}
end
