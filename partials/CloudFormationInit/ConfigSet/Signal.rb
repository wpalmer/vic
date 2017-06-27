Proc.new do |
	resource: nil,
	id: nil
|
	if id.nil?
		id = ''
	else
		id = "--id \"#{id}\""
	end
	{
		"commands" => {
			"01_signal" => {
				"command" => interpolate(<<-END_SH.gsub(/^\s+/, ""), {r: resource, id: id}
					#!/bin/bash -xe
					/opt/aws/bin/cfn-signal \
						--success true \
						{{locals[:id]}} \
						--region {{ref('AWS::Region')}} \
						--resource {{locals[:r]}} \
						--stack {{ref('AWS::StackName')}}
				END_SH
				)
			}
		}
	}
end
