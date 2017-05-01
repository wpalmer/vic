Proc.new do |
	addressAllocationIds: [], # array of Elastic IP Address allocation ids
	doDockerRestart: false, # whether or not to restart the docker service
	doECSRestart: false # whether or not to restart the ECS service
|
	{
		"commands" => {
			"00_associate_address" => {
				"test" => interpolate(<<-END_SH.gsub(/^\s+/, ""), {addr: addressAllocationIds}
					#!/bin/bash -xe
					AWS_CMD="$(PATH=/usr/local/bin:/usr/bin:/bin which aws)"
					EC2_INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
					AWS_DEFAULT_REGION={{ref('AWS::Region')}}
					export AWS_DEFAULT_REGION
					EIP_IDS=( {{ join(" ", *locals[:addr]) }} )

					already=0
					available=0
					for eip in "${EIP_IDS[@]}"; do
						response_json="$(
							"$AWS_CMD" ec2 describe-addresses --allocation-ids $eip
						)"

						eip_association="$(
							jq -r '
								.Addresses[].AssociationId // empty
							' <<<"$response_json"
						)"
						eip_attached_instance="$(
							jq -r '
								.Addresses[].InstanceId // empty
							' <<<"$response_json"
						)"

						[[ "$eip_attached_instance" = "$EC2_INSTANCE_ID" ]] && already=1 && break
						[[ -z "$eip_association" ]] && available=1
					done
					[[ $available -eq 1 ]] && [[ $already -eq 0 ]] && exit 0
					exit 1
				END_SH
				),
				"command" => interpolate(<<-END_SH.gsub(/^\s+/, ""), {addr: addressAllocationIds}
					#!/bin/bash -xe
					AWS_CMD="$(PATH=/usr/local/bin:/usr/bin:/bin which aws)"
					EC2_INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
					AWS_DEFAULT_REGION={{ref('AWS::Region')}}
					export AWS_DEFAULT_REGION
					EIP_IDS=( {{ join(" ", *locals[:addr]) }} )

					for eip in "${EIP_IDS[@]}"; do
						response_json="$(
							"$AWS_CMD" ec2 describe-addresses --allocation-ids $eip
						)"
						eip_association="$(
							jq -r '
								.Addresses[].AssociationId // empty
							' <<<"$response_json"
						)"

						if [[ -z "$eip_association" ]]; then
							"$AWS_CMD" ec2 associate-address \\
								--instance-id "$EC2_INSTANCE_ID" \\
								--allocation-id "$eip"
						fi
					done
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
