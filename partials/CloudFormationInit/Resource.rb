Proc.new do |
	resourceName,
	type: "AWS::AutoScaling::LaunchConfiguration",
	metadata: {},
	properties: {},
	dependson: nil,
	extraUserData: nil,
	signalResourceName: nil
|
	resource resourceName, {
		:Type => type,
		:Metadata => metadata.merge({
			"AWS::CloudFormation::Authentication" =>
				if metadata.has_key? "AWS::CloudFormation::Authentication"
					metadata["AWS::CloudFormation::Authentication"]
				else
					{}
				end,
			"AWS::CloudFormation::Init" =>
				{
					"config" => {},
					"common" => {},
					"cfn" => {
						"files" => {
							"/etc/cfn/cfn-hup.conf" => {
								"content" => interpolate(<<-END_INI.gsub(/^\s+/, "")
									[main]
									stack={{ref('AWS::StackId')}}
									region={{ref('AWS::Region')}}
									interval=1
									verbose=true
								END_INI
								),
								"mode" => "000400",
								"owner" => "root",
								"group" => "root"
							},
							"/etc/cfn/hooks.d/cfn-auto-reloader.conf" => {
								"content" => interpolate(<<-END_INI.gsub(/^\s+/, "").gsub(/(\s)\s+/, '\1')
									[cfn-auto-reloader-hook]
									triggers=post.update
									path=Resources.#{ resourceName }.Metadata.AWS::CloudFormation::Init
									action=/opt/aws/bin/cfn-init -v \
										--stack {{ref('AWS::StackName')}} \
										--resource #{ resourceName } \
										--region {{ref('AWS::Region')}} \
										--configsets cfnUpdate
									runas=root
								END_INI
								)
							}
						},
						"services" => {
							"sysvinit" => {
								"cfn-hup" => {
									"enabled" => "true",
									"ensureRunning" => "true",
									"files" => [
										"/etc/cfn/cfn-hup.conf",
										"/etc/cfn/hooks.d/cfn-auto-reloader.conf"
									]
								}
							}
						}
					}
				}.merge(
					if metadata.has_key? "AWS::CloudFormation::Init"
						Hash[metadata["AWS::CloudFormation::Init"].map{|k,v|[k.to_s, v]}]
					else
						{}
					end
				).merge(
					{
						"configSets" => {
							"default" => ["config"],
							"cfnInit" => ["cfn", {"ConfigSet" => "default"}],
							"cfnUpdate" => ["cfn", {"ConfigSet" => "default"}]
						}.merge(
							if metadata.has_key?("AWS::CloudFormation::Init")
								initdata = Hash[
									metadata["AWS::CloudFormation::Init"].map{|k,v|[k.to_s, v]}
								]
								if initdata.has_key?("configSets")
									Hash[ initdata["configSets"].map{|k,v|[k.to_s, v]} ]
								else
									{}
								end
							else
								{}
							end
						)
					}
				)
		}),
		:Properties => {
			UserData: base64(interpolate(<<-END_SH.gsub(/^\s+/, "").gsub(/(\s)\s+/, '\1'), {u: extraUserData}
				#!/bin/bash -xe
				yum install -y aws-cfn-bootstrap
				yum update -y aws-cfn-bootstrap

				/opt/aws/bin/cfn-init -v \
					--stack {{ref('AWS::StackName')}} \
					--resource #{ resourceName } \
					--region {{ref('AWS::Region')}} \
					--configsets cfnInit

				#{
					unless signalResourceName.nil?
						[
							'/opt/aws/bin/cfn-init -v',
								'--stack', ref('AWS::StackName'),
								'--resource', signalResourceName,
								'--region', ref('AWS::Region'),
								'--configsets cfnInit'
						].join(' ')
					end
				}

				{{ if locals[:u].nil? then '' else locals[:u] end }}
			END_SH
			))
		}.merge(properties)
	}.merge(
		if !dependson.nil?
			{ :DependsOn => dependson }
		else {} end
	)
end
