Proc.new do |
	volumes: [], # [{id: "anEBSVolumeId", device: "targetDevice", path: "targetHostPath"}]
	doPartition: false, # whether or not to create partitions when none exist
	doFormat: false, # whether or not to format when no filesystem exists
	doDockerRestart: false, # whether or not to restart the docker service
	doECSRestart: false # whether or not to restart the ECS service
|
	{
		"commands" => {
			"01_attach_persistent_data" => {
				"test" => interpolate(<<-END_SH.gsub(/^\s+/, ""), {v: volumes}
					#!/bin/bash -xe
					AWS_CMD="$(PATH=/usr/local/bin:/usr/bin:/bin which aws)"
					EC2_INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
					AWS_DEFAULT_REGION={{ref('AWS::Region')}}
					export AWS_DEFAULT_REGION

					EBS_IDS=( {{ join(" ", *locals[:v].map{|v| v[:id] }) }} )

					for ebs in "${EBS_IDS[@]}"; do
						attachment_state="$(
							$AWS_CMD ec2 describe-volumes \\
								--volume-id "$ebs" |
							jq -r '
								.Volumes[].Attachments[] |
								select( .InstanceId == "'"$EC2_INSTANCE_ID"'" ).State
							'
						)"

						if [[ "$attachment_state" = "attached" ]]; then
							continue
						else
							exit 0
						fi
					done

					exit 1
				END_SH
				),
				"command" => interpolate(<<-END_SH.gsub(/^\s+/, ""), {v: volumes}
					#!/bin/bash -xe
					AWS_CMD="$(PATH=/usr/local/bin:/usr/bin:/bin which aws)"
					EC2_INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
					AWS_DEFAULT_REGION={{ref('AWS::Region')}}
					export AWS_DEFAULT_REGION

					EBS_IDS=( {{ join(" ", *locals[:v].map{|v| join(":", *[ v[:id], v[:device] ]) }) }} )

					for ebs in "${EBS_IDS[@]}"; do
						ebsid="${ebs%%:*}"
						ebsdevice="${ebs#*:}"
						"$AWS_CMD" ec2 attach-volume \\
							--volume-id $ebsid \\
							--instance-id "$EC2_INSTANCE_ID" \\
							--device $ebsdevice
					done

					sleep 1

					for ebs in "${EBS_IDS[@]}"; do
						ebsid="${ebs%%:*}"
						ebsdevice="${ebs#*:}"
						n=0
						while true; do
							attachment_state="$(
								"$AWS_CMD" ec2 describe-volumes \\
									--volume-id $ebsid |
								jq -r '
									.Volumes[].Attachments[] |
									select( .InstanceId == "'"$EC2_INSTANCE_ID"'" ).State
								'
							)"

							case "$attachment_state" in
								'')
									if [[ $n -gt 5 ]]; then
										printf 'attachment of %s to %s:%s never initiated\\n' \\
											"$ebsid" \\
											"$EC2_INSTANCE_ID" \\
											"$ebsdevice" \\
											>&2
										exit 1
									fi

									sleep 5

									n=$(( $n + 1 ))
									"$AWS_CMD" ec2 attach-volume \\
										--volume-id $ebsid \\
										--instance-id "$EC2_INSTANCE_ID" \\
										--device $ebsdevice

									sleep 1
									;;
								attaching)
									sleep 1
									;;
								attached)
									break
									;;
								*)
									printf "$attachment_state" >&2
									exit 1
									;;
							esac
						done
					done
				END_SH
				)
			},
			"02_partition_persistent_data" => {
				"test" =>
					unless doPartition
						"#!/bin/bash -xe\n# doPartition is disabled\nexit 1\n"
					else
						interpolate(<<-END_SH.gsub(/^\s+/, ""), {v: volumes}
							#!/bin/bash -xe
							EBS_DEVICES=( {{ join(" ", *locals[:v].map{|v| v[:device] }) }} )

							for ebs in "${EBS_DEVICES[@]}"; do
								if [[ "$(lsblk -lnmf ${ebs} | wc -l)" = "1" ]]; then
									fs="$(lsblk -lnmf ${ebs} | awk '{print $7}')"
									if [[ -z "$fs" ]]; then
										exit 0
									fi
								fi
							done
							exit 1
						END_SH
						)
					end,
				"command" => interpolate(<<-END_SH.gsub(/^\s+/, ""), {v: volumes}
					#!/bin/bash -xe
					EBS_DEVICES=( {{ join(" ", *locals[:v].map{|v| v[:device] }) }} )

					for ebs in "${EBS_DEVICES[@]}"; do
						if [[ "$(lsblk -lnmf ${ebs} | wc -l)" = "1" ]]; then
							fs="$(lsblk -lnmf ${ebs} | awk '{print $7}')"
							if [[ -z "$fs" ]]; then
								parted -s -a optimal ${ebs} \\
									mklabel gpt -- \\
									mkpart primary ext4 1 -1
							fi
						fi
					done
				END_SH
				)
			},
			"03_format_persistent_data" => {
				"test" =>
					unless doFormat
						"#!/bin/bash -xe\n# doFormat is disabled\nexit 1\n"
					else
						interpolate(<<-END_SH.gsub(/^\s+/, ""), {v: volumes}
							#!/bin/bash -xe
							EBS_DEVICES=( {{ join(" ", *locals[:v].map{|v| v[:device] }) }} )

							for ebs in "${EBS_DEVICES[@]}"; do
								if [[ "$(lsblk -lnmf ${ebs} | wc -l)" = "2" ]]; then
									fs="$(lsblk -lnmf $ebs | awk 'NR==2{print $7}')"
									if [[ -z "$fs" ]]; then
										exit 0
									fi
								fi
							done
							exit 1
						END_SH
						)
					end,
				"command" => interpolate(<<-END_SH.gsub(/^\s+/, ""), {v: volumes}
					#!/bin/bash -xe
					EBS_DEVICES=( {{ join(" ", *locals[:v].map{|v| v[:device] }) }} )

					for ebs in "${EBS_DEVICES[@]}"; do
						if [[ "$(lsblk -lnmf $ebs | wc -l)" = "2" ]]; then
							fs="$(lsblk -lnmf $ebs | awk 'NR==2{print $7}')"
							if [[ -z "$fs" ]]; then
								mkfs -t ext4 /dev/xvd${ebs#/dev/sd}1
							fi
						fi
					done
				END_SH
				)
			},
			"04_mount_persistent_data" => {
				"test" => interpolate(<<-END_SH.gsub(/^\s+/, ""), {v: volumes}
					#!/bin/bash -xe
					EBS_DEVICES=( {{ join(" ", *locals[:v].map{|v| v[:device] }) }} )

					for ebs in "${EBS_DEVICES[@]}"; do
						if \\
							grep -q /dev/xvd${ebs#/dev/sd}1 /etc/fstab &&
							grep -q /dev/xvd${ebs#/dev/sd}1 /etc/mtab
						then
							continue
						else
							exit 0
						fi
					done
					exit 1
				END_SH
				),
				"command" => interpolate(<<-END_SH.gsub(/^\s+/, ""), {v: volumes}
					#!/bin/bash -xe
					EBS_DEVICES=( {{ join(" ", *locals[:v].map{|v| join(":", *[ v[:device], v[:path] ]) }) }} )

					mounts=0
					for ebs in "${EBS_DEVICES[@]}"; do
						ebsdevice="${ebs%%:*}"
						ebspath="${ebs#*:}"
						[[ -b /dev/xvd${ebsdevice#/dev/sd}1 ]] || exit 1
						mkdir -p ${ebspath}
						grep -q /dev/xvd${ebsdevice#/dev/sd}1 /etc/fstab ||
						printf '%s %s ext4 defaults 0 0\\n' \\
							"/dev/xvd${ebsdevice#/dev/sd}1" \\
							"${ebspath}" \\
							>> /etc/fstab

						if ! grep -q /dev/xvd${ebsdevice#/dev/sd}1 /etc/mtab; then
							mount ${ebspath}
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
				"jq" => []
			},
			"python" => {
				"awscli" => []
			}
		}
	}
end
