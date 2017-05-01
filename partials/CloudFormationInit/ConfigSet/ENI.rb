Proc.new do |
	elasticNetworkInterfaceIds: [], # array of Elastic Network Interface ids
	doDockerRestart: false, # whether or not to restart the docker service
	doECSRestart: false # whether or not to restart the ECS service
|
	{
		"commands" => {
			"00_attach_elastic_network_interfaces" => {
				"test" => interpolate(<<-END_SH.gsub(/^\s+/, ""), {eni_ids: elasticNetworkInterfaceIds}
					#!/bin/bash -xe
					AWS_CMD="$(PATH=/usr/local/bin:/usr/bin:/bin which aws)"
					EC2_INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
					AWS_DEFAULT_REGION={{ref('AWS::Region')}}
					export AWS_DEFAULT_REGION
					ENI_IDS=( {{join(" ", *locals[:eni_ids])}} )

					for eni in "${ENI_IDS[@]}"; do
						response_json="$(
							"$AWS_CMD" ec2 describe-network-interfaces \\
								--network-interface-id $eni
						)"
						eni_status="$(
							jq -r '
								.NetworkInterfaces[].Attachment.Status
							' <<<"$response_json"
						)"
						eni_attached_instance="$(
							jq -r '
								.NetworkInterfaces[].Attachment.InstanceId
							' <<<"$response_json"
						)"

						if \\
							[[ "$eni_status" != "attached" ]] ||
							[[ "$eni_attached_instance" != "$EC2_INSTANCE_ID" ]]
						then
							exit 0
						fi
					done
				END_SH
				),
				"command" => interpolate(<<-END_SH.gsub(/^\s+/, ""), {eni_ids: elasticNetworkInterfaceIds}
					#!/bin/bash -xe
					AWS_CMD="$(PATH=/usr/local/bin:/usr/bin:/bin which aws)"
					EC2_INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
					AWS_DEFAULT_REGION={{ref('AWS::Region')}}
					export AWS_DEFAULT_REGION
					ENI_IDS=( {{join(" ", *locals[:eni_ids])}} )

					i=0
					did_attach=0
					for eni in "${ENI_IDS[@]}"; do
						i=$(( $i + 1 ))
						response_json="$(
							"$AWS_CMD" ec2 describe-network-interfaces \\
								--network-interface-id "$eni"
						)"
						eni_status="$(
							jq -r '
								.NetworkInterfaces[].Attachment.Status
							' <<<"$response_json"
						)"
						eni_attached_instance="$(
							jq -r '
								.NetworkInterfaces[].Attachment.InstanceId
							' <<<"$response_json"
						)"

						if \\
							[[ "$eni_status" != "attached" ]] ||
							[[ "$eni_attached_instance" != "$EC2_INSTANCE_ID" ]]
						then
							"$AWS_CMD" ec2 attach-network-interface \\
								--network-interface-id "$eni" \\
								--instance-id "$EC2_INSTANCE_ID" \\
								--device-index $i || exit 1

							did_attach=1
						fi
					done

					for eni in "${ENI_IDS[@]}"; do
						eni_status=
						while true; do
							response_json="$(
								"$AWS_CMD" ec2 describe-network-interfaces \\
									--network-interface-id "$eni"
							)"
							eni_status="$(
								jq -r '
									.NetworkInterfaces[].Attachment.Status
								' <<<"$response_json"
							)"

							case "$eni_status" in
								attached)
									break
									;;
								attaching|'')
									sleep 1 # we are not expecting attachment to take a long time
									;;
								*)
									printf '%s reached unexpected state "%s" prior to "attached"\n' \\
										"$eni" \\
										"$eni_status" \\
										>&2
									;;
							esac
						done
					done

					i=0
					routes=
					for eni in "${ENI_IDS[@]}"; do
						i=$(( $i + 1 ))
						device=eth$i
						device_routes=
						while [[ -z "$device_routes" ]]; do
							sleep 1
							device_routes="$(
								ip route list dev $device |
									sed -n '/^\\(default\\|[0-9]\\)/{ s/ .*//;p; }'
							)"
						done

						routes="$routes $device_routes"
					done

					ifdown eth0 || true

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
				"ec2-net-utils" => [],
				"jq" => []
			},
			"python" => {
				"awscli" => []
			}
		}
	}
end
